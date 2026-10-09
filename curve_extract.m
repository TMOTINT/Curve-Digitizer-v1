
function [C, info] = curve_extract(I, fr, rg, nExpect, opt)
%CURVE_EXTRACT  颜色感知全局 DP 曲线提取（同色系多条 / 相互交叉 / 带散点误差棒都适用）
%
%   用途它：
%     旧链路是"骨架 + 逐列贪心 + DP 精化"，颜色不参与分离。fig3A（黑+6 条深浅绿）
%     与 fig3D（10 条绿族、互相交叉）里浅色线对比度低，会被深色线吸走 —— 整段没人认领。
%
%   五个阶段（每一阶段针对一类具体问题）：
%     ① 墨迹掩膜      亮度/色度阈值；去长轴脊；去贴轴脊的短刻度线；去图例/文字遮挡框；
%                     可选 inkMax 只认深色墨迹（fig2E 排除灰色单次记录）。
%     ② 颜色候选      腐蚀取核心像素 -> k-means -> 按"能在多少不同列上成为最优匹配"打分。
%                     刻度/虚线只在个别列出现，得分极低，自动淘汰。
%     ③ 逐候选 DP     混色似然（alpha 解混 + 残差）+ 竞争项；逐列一阶 DP，
%                     转移用抛物线下包络精确求解，惩罚 lam*d^2 且不限步长
%                     （硬步长限制会让 fig2E 陡降 / fig3F 锯齿变成"不可达"，
%                       全局最优于是绕开曲线走空白，覆盖率直接掉到 0.19）。
%                     亚像素用"本线似然"界定笔画范围后取加权重心（不能用固定 ±6 窗口：
%                     粗线会被切掉一侧，实测中位偏移 3.5 px）。
%     ④ 最大覆盖选路   贪心挑选能覆盖最多尚未被覆盖墨迹的路径 —— 直接优化"重合度"。
%     ⑤ 漏检回收       仍有成片墨迹没人认领时：取其颜色再求一条路径，重新选路。循环迭代。
%                     这一步专治 fig3D 那种"某条曲线整条没人认领"的情况。
%
%   选项：colors Kx3 指定颜色 | K/extraK 候选数 | sigma(45) 残差尺度 | beta(0.5) 竞争
%         lam(0.02) 斜率惩罚 | inkPen(1) 非墨迹罚 | inkMax 灰度上限 | block 遮挡框
%         colTol(25) 颜色去重 | minEvid(0.45) 墨迹证据下限 | gapIter(4) 回收轮数
%         gapArea(0.0015) 回收块最小面积占比 | subW(6) 亚像素兜底窗
if nargin < 5, opt = struct(); end
gf = @(f,d) getf(opt,f,d);
d = double(I); [H,W,~] = size(I);
g = mean(d,3)/255; ch = (max(d,[],3)-min(d,[],3))/255;
rTop = max(1, round(fr(1))+3); rBot = min(H, round(fr(2))-3);
cLft = max(1, round(fr(3))+3); cRgt = min(W, round(fr(4))-3);
inner = false(H,W); inner(rTop:rBot, cLft:cRgt) = true;
ink = inner & ((g < 0.88) | (ch > 0.08));
if isfield(opt,'inkMax'), ink = ink & (g < opt.inkMax); end
% 去轴脊（整行/整列墨占比高）
f1 = mean(ink(:,cLft:cRgt),2); bad = find(f1 > 0.45);
for r = bad', ink(max(1,r-4):min(H,r+4), :) = false; end
f2 = mean(ink(rTop:rBot,:),1); bad = find(f2 > 0.35);
for c = bad, ink(:, max(1,c-4):min(W,c+4)) = false; end
blk = gf('block',[]);
if ~isempty(blk)
   % 遮挡框必须取整：界面按图像尺寸缩放后会带小数，冒号索引遇到非整数会告警/越界
   blk = round(double(blk(:)'));
   blk = max(1, blk);
   r0 = min(H, blk(1)); r1 = min(H, blk(2)); cc0 = min(W, blk(3)); cc1 = min(W, blk(4));
   if r1 >= r0 && cc1 >= cc0, ink(r0:r1, cc0:cc1) = false; end
end
inkColor = ink;   % 颜色估计用未过滤掩膜：保证后续过滤不改变聚类结果（可复现）
% 去"贴轴脊、又短又扁"的连通域 = 坐标轴刻度线
if any(ink(:))
   CC = bwlabel(ink, 8);
   st = regionprops(CC, 'BoundingBox', 'PixelIdxList');
   wmin = gf('minSpanFrac', 0.06) * (cRgt - cLft);
   hmax = gf('minTallFrac', 0.05) * (rBot - rTop);
   for q = 1:numel(st)
      bb = st(q).BoundingBox;
      touchLR = (bb(1) <= cLft + 10) || (bb(1)+bb(3) >= cRgt - 10);
      touchTB = (bb(2) <= rTop + 10) || (bb(2)+bb(4) >= rBot - 10);
      if (touchLR && bb(3) < wmin) || (touchTB && bb(4) < hmax)
         ink(st(q).PixelIdxList) = false;
      end
   end
end
ink = bwareaopen(ink, 3, 8);

% ---- 笔画"横向半宽"：用距离变换的脊值，而不是竖向 run 长度 ----
% 竖向 run 长度对近竖直的笔画会虚高（fig3F 中线宽能算出 39 px），
% 而 D=bwdist(~ink) 在笔画中心等于"到背景的垂直距离"= 真正的半宽。
Dd = bwdist(~ink);
ridge = [];
for c = cLft:cRgt
   rr = find(ink(:,c)); if isempty(rr), continue; end
   bk = [0;find(diff(rr)>2);numel(rr)];
   for t = 1:numel(bk)-1
      gr = rr(bk(t)+1:bk(t+1));
      ridge(end+1) = max(Dd(gr, c)); %#ok<AGROW>
   end
end
wLine = max(1.5, median(ridge));
P = reshape(d, [], 3); PW = 255 - P;
ctx = struct('H',H,'W',W,'rTop',rTop,'rBot',rBot,'cLft',cLft,'cRgt',cRgt, ...
   'nC',cRgt-cLft+1,'cs',(cLft:cRgt)','PW',PW,'P',P,'ink',ink, ...
   'sigma',gf('sigma',45),'beta',gf('beta',0.5),'inkPen',gf('inkPen',1.0), ...
   'lam',gf('lam',0.02),'subW',gf('subW',6),'covW',round(gf('covW',6)), ...
   'minPts',gf('minPts',40),'minEvid',gf('minEvid',0.45),'fr',fr,'rg',rg, ...
   'Dd',Dd,'wLine',wLine,'wThick',gf('wThick',0.45),'dupFrac',gf('dupFrac',0.75));   % 默认只拦几乎完全重合的重复；按图可在 extract_opts 调低

% ---- 阶段2：颜色候选 ----
CAND = gf('colors', []); SC = [];
if isempty(CAND)
   [CAND, SC] = estimateColors(inkColor, d, nExpect + round(gf('extraK',4)), gf('colTol',25));
   [~, oo] = sort(SC, 'descend'); CAND = CAND(oo,:); SC = SC(oo);
end
if ~isempty(CAND)
   Lall = LallOf(CAND, PW, ctx.sigma);
   [bestL, bestI] = max(Lall, [], 2);
   ctx.BLg = double(bestL); ctx.BIg = bestI; ctx.CAND = CAND;
   ctx.Lsum = double(sum(Lall, 2));      % softmax 归一化用
   ctx.softmax = gf('softmax', false);
else
   ctx.BLg = zeros(size(P,1),1); ctx.BIg = ones(size(P,1),1); ctx.CAND = zeros(0,3);
   ctx.Lsum = ones(size(P,1),1); ctx.softmax = false;
end

% ---- 阶段3：每个候选色求一条全局最优路径 ----
K = size(CAND,1);
PAT = cell(K,1); COV = cell(K,1); COST = inf(K,1); EVID = zeros(K,1);
for j = 1:K
   [Pj, cv, cn, ev] = onePath(CAND(j,:), ctx);
   if isempty(Pj), continue; end
   PAT{j} = Pj; COV{j} = cv; COST(j) = cn; EVID(j) = ev;
end

% ---- 阶段4/5：最大覆盖选路 + 漏检回收（迭代） ----
nWant = max(0, round(nExpect));
if nWant == 0
   C = struct('X',{},'Y',{},'px',{},'py',{},'core',{},'cover',{},'cost',{},'evid',{});
   info = struct('cand',CAND,'score',SC,'nCurve',0);
   return;
end
sel = pickCover(PAT, COV, ctx, nWant);
gapArea = max(120, round(gf('gapArea',0.0015) * sum(ctx.ink(:))));
for it = 1:round(gf('gapIter',4))
   covered = false(H,W);
   for j = sel, covered = covered | COV{j}; end
   unc = ctx.ink & ~covered;
   unc = bwareaopen(unc, gapArea, 8);
   if ~any(unc(:)), break; end
   CC = bwlabel(unc, 8); st = regionprops(CC, 'PixelIdxList', 'Area');
   nAdd = 0;
   for q = 1:numel(st)
      if st(q).Area < gapArea, continue; end
      cj = median(ctx.P(st(q).PixelIdxList, :), 1);
      if any(sqrt(sum((CAND - cj).^2, 2)) < 1e-9), continue; end
      [Pj, cv, cn, ev] = onePath(cj, ctx);
      if isempty(Pj), continue; end
      % 这条新路径至少要认出该漏检块的一半
      hit = sum(unc(st(q).PixelIdxList));
      if hit < 0.35 * st(q).Area, continue; end
      CAND(end+1,:) = cj; PAT{end+1} = Pj; COV{end+1} = cv; %#ok<AGROW>
      COST(end+1) = cn; EVID(end+1) = ev; %#ok<AGROW>
      nAdd = nAdd + 1;
   end
   if nAdd == 0, break; end
   sel = pickCover(PAT, COV, ctx, nWant);
end

% ---- 输出：先做两级后处理，再把像素坐标换算成数据坐标 ----
%   ⑥ 颜色重吸附 snap_to_color：逐列回到"本曲线颜色"的墨峰，纠正被圆点/粘连带偏的行。
%   ⑦ 光滑先验 snake_smooth：一维主动轮廓，把尖刺/钩子这类粗差压掉，
%      平滑强度由偏差原则自动定（真实抖动的数据不会被抹平）。
C = struct('X',{},'Y',{},'px',{},'py',{},'core',{},'cover',{},'cost',{},'evid',{});
for j = sel
   Pj = PAT{j}; fr1 = ctx.fr; rg1 = ctx.rg;
   cs2 = Pj(:,1); rs2 = Pj(:,2); cj = CAND(j,:);
   if isfield(opt,'snapWin') && opt.snapWin > 0
      [~, rs2] = snap_to_color(I, cs2, rs2, cj, struct('win', opt.snapWin));
   end
   if isfield(opt,'normal') && opt.normal
      rs2 = refine_normal(I, cs2, rs2, cj, struct('win', round(2.5*ctx.wLine)));
   end
   if isfield(opt,'smooth')
      sm = opt.smooth; sm.wLine = ctx.wLine;      % 厚度置信度需要实测线宽
      rs2 = snake_smooth(cs2, rs2, I, sm);
   end
   if isfield(opt,'blackCenter') && opt.blackCenter
      rs2 = black_stroke_center(I,cs2,rs2,fr1);
   end
   Pj = [cs2 rs2];
   X = (Pj(:,1) - fr1(3))*(rg1(2)-rg1(1))/(fr1(4)-fr1(3)) + rg1(1);
   Y = rg1(4) - (Pj(:,2) - fr1(1))*(rg1(4)-rg1(3))/(fr1(2)-fr1(1));
   C(end+1) = struct('X',X,'Y',Y,'px',Pj(:,1),'py',Pj(:,2),'core',cj, ...
      'cover',EVID(j),'cost',COST(j),'evid',EVID(j)); %#ok<AGROW>
end
% Only explicitly selected panels use evidence correction (no smoothing).
if isfield(opt,'precisionMode')
   C = targeted_trace(I, C, fr, rg, opt);
end
info = struct('cand',CAND,'score',SC,'nCurve',numel(C));
if ~isempty(C)
   mid = arrayfun(@(c) median(c.py), C);
   [~, o] = sort(mid); C = C(o);
end
end

%
function [P, cov, costN, evid] = onePath(cj, ctx)
% 对给定颜色求一条全局最优路径，并做亚像素 + 证据校验 + 首尾裁剪
H = ctx.H; W = ctx.W; nC = ctx.nC; cs = ctx.cs;
Lk = double(LallOf(cj, ctx.PW, ctx.sigma));
comp = sqrt(sum((ctx.CAND(ctx.BIg,:) - cj).^2, 2)) > 1e-9;
% 竞争项：默认是"惩罚+软引导"；softmax=1 时改用归一化似然
%   Lk/sum_j Lj —— 一个像素若更能被别的曲线解释，本曲线的代价就显著抬高。
%   对同色系、互相贴住的曲线族（fig3D）比软引导尖锐得多，明显抑制"在两线之间跳"。
if ctx.softmax
   Lk = Lk ./ max(ctx.Lsum, 1e-6);
   E = reshape(1 - Lk, H, W);
else
   E = reshape(1 - Lk + ctx.beta * ctx.BLg .* double(comp), H, W);
end
% 厚度惩罚：数据圆点/误差棒/图例笔画与曲线同色，光靠颜色分不开（实测 fig3C 有
% 23.5% 的路径点落在大点上）。用距离变换把"比线宽更厚的结构"抬价，路径自然回到细线上。
if ctx.wThick > 0
   E = E + ctx.wThick * max(0, ctx.Dd - ctx.wLine - 1);
end
E(~ctx.ink) = 1 + ctx.beta + ctx.inkPen;
Em = inf(H, nC); Em(:, :) = E(:, ctx.cLft:ctx.cRgt);
Em(1:ctx.rTop-1, :) = inf; Em(ctx.rBot+1:end, :) = inf;
[rs, cost] = dpPath(Em, ctx.lam);
P = []; cov = []; costN = inf; evid = 0;
if isempty(rs), return; end
rs = rs(:);
% 亚像素：用"本线似然"界定笔画范围（比二值 ink 更贴合本线；粗线不会被灰迹带偏）
Lmv = reshape(Lk, H, W); Lm = Lmv .* double(ctx.ink);
rs2 = rs; thr = 0.15;
for q = 1:nC
   c = cs(q); r0 = round(rs(q));
   a = r0; b = r0;
   while a > ctx.rTop && Lmv(a-1, c) > thr, a = a - 1; end
   while b < ctx.rBot && Lmv(b+1, c) > thr, b = b + 1; end
   if b - a < 2, a = max(ctx.rTop, r0-ctx.subW); b = min(ctx.rBot, r0+ctx.subW); end
   % 关键：窗口不能顺着"同色且相连的竖直结构"无限外扩。
   % fig3E 的数据圆点画在曲线下方，靠误差棒的竖杆与曲线连成一体、且同色 ——
   % 一路外扩会把加权重心拽进圆点里（实测蓝线在此处下陷 12 px 又弹回）。
   % 把窗口夹到 ±2.5 倍线宽，既罩得住粗线（fig2E 线宽 18 px），又够不到远处的圆点。
   halfMax = max(ctx.subW, round(2.5*ctx.wLine));
   a = max(a, r0 - halfMax); b = min(b, r0 + halfMax);
   a2 = max(ctx.rTop, a-3); b2 = min(ctx.rBot, b+3);
   ww = Lm(a2:b2, c);
   if sum(ww) > 1e-6, rs2(q) = sum((a2:b2)'.*ww)/sum(ww); end
end
onv = ctx.ink(sub2ind([H W], min(max(round(rs2),1),H), cs));
fq = find(onv, 1); lq = find(onv, 1, 'last');
if isempty(fq) || lq - fq < ctx.minPts, return; end
keep = fq:lq;
if mean(onv(keep)) < ctx.minEvid, return; end
P = [cs(keep) rs2(keep)];
cov = coverMask(P, H, W, ctx.covW);
costN = cost / numel(keep);
evid = mean(onv(keep));
end

%
function sel = pickCover(PAT, COV, ctx, nWant)
% 贪心最大覆盖：每轮挑能覆盖最多"尚未被覆盖墨迹"的路径。
% 额外加一条硬约束：与已选路径"落在同一笔画"超过 40% 的列 -> 判为同一条曲线的
% 重复候选，直接跳过。否则两条路径会挤在同一根线上，另一根线没人认领
% （实测 fig3C 有 41%、fig3D 有 55% 的列出现这种撞车）。
uncovered = ctx.ink; sel = [];
thr = ctx.dupFrac;
for it = 1:nWant
   bestG = 0; bj = 0;
   for j = 1:numel(PAT)
      if isempty(PAT{j}) || any(sel == j), continue; end
      dup = false;
      for s = sel
         if sameStrokeFrac(PAT{j}, PAT{s}, ctx.ink, ctx.H) > thr, dup = true; break; end
      end
      if dup, continue; end
      gg = sum(uncovered(COV{j}));
      if gg > bestG, bestG = gg; bj = j; end
   end
   if bj == 0, break; end
   sel(end+1) = bj; %#ok<AGROW>
   uncovered = uncovered & ~COV{bj};
end
end

function fr = sameStrokeFrac(P1, P2, ink, H)
% 两条路径有多大比例的列"落在同一个墨迹 run 里"（中间没有空白隔开）
[cc, ia, ib] = intersect(P1(:,1), P2(:,1));
fr = 0;
if numel(cc) < 30, return; end
r1 = P1(ia,2); r2 = P2(ib,2);
q = (1:3:numel(cc))';            % 每 3 列抽样，够用且快
n = 0; m = 0;
for t = 1:numel(q)
   c = cc(q(t));
   lo = max(1, ceil(min(r1(q(t)), r2(q(t)))));
   hi = min(H, floor(max(r1(q(t)), r2(q(t)))));
   n = n + 1;
   if hi <= lo || all(ink(lo:hi, c)), m = m + 1; end
end
if n > 0, fr = m/n; end
end

%
function [CEN, score] = estimateColors(ink, d, K, colTol)
% 核心像素（腐蚀掉抗锯齿边缘）-> 颜色聚类 -> 按"覆盖多少不同列"打分
[H, W, ~] = size(d);
core = imerode(ink, strel('disk', 1));
if sum(core(:)) < 1500, core = ink; end
idx = find(core); P = reshape(d, [], 3); Pc = P(idx, :);
[~, cc] = ind2sub([H W], idx);
if isempty(Pc), CEN = [0 0 0]; score = 0; return; end
K = max(1, min(K, size(Pc,1)));
CEN = kmeansR(Pc, K, 5);
[~, lab] = min(sqdist(CEN, Pc), [], 1); lab = lab(:);
score = zeros(K,1);
for k = 1:K, score(k) = numel(unique(cc(lab == k))); end
o = sortrows([score (1:K)'], -1);
keep = [];
for q = 1:K
   k = o(q,2);
   if isempty(keep) || all(sqrt(sum((CEN(keep,:) - CEN(k,:)).^2, 2)) >= colTol)
      keep(end+1) = k; %#ok<AGROW>
   end
end
CEN = CEN(keep,:); score = score(keep);
end

function L = LallOf(CEN, PW, sigma)
N = size(PW,1); K = size(CEN,1);
L = zeros(N, K, 'single');
for k = 1:K
   v = (255 - CEN(k,:))'; n2 = v'*v;
   al = min(max((PW*v)/n2, 0), 1);
   rz = sqrt(sum((PW - al*v').^2, 2));
   L(:,k) = single(al .* exp(-(rz/sigma).^2));
end
end

function [rs, cost] = dpPath(E, lam)
% D(r,q) = E(r,q) + min_{r'} [ D(r',q-1) + lam*(r-r')^2 ]，下包络精确求解，O(H) 每列
[H, nC] = size(E);
BIG = 1e9;
E(~isfinite(E) | E > BIG) = BIG;
D = zeros(H, nC); BP = zeros(H, nC, 'int32');
D(:,1) = E(:,1);
for q = 2:nC
   [gq, arg] = minPlusQuad(D(:,q-1), lam);
   D(:,q) = E(:,q) + gq; BP(:,q) = arg;
end
[cost, r] = min(D(:,end));
rs = zeros(nC,1); rs(nC) = r;
for q = nC:-1:2, rs(q-1) = BP(rs(q), q); end
rs = min(max(rs, 1), H);
if cost >= BIG, rs = []; end
end

function [g, arg] = minPlusQuad(f, eps2)
n = numel(f);
v = zeros(n,1); z = zeros(n+1,1);
k = 1; v(1) = 1; z(1) = -inf; z(2) = inf;
for q = 2:n
   s = ((f(q) + eps2*q*q) - (f(v(k)) + eps2*v(k)*v(k))) / (2*eps2*(q - v(k)));
   while k > 1 && s <= z(k)
      k = k - 1;
      s = ((f(q) + eps2*q*q) - (f(v(k)) + eps2*v(k)*v(k))) / (2*eps2*(q - v(k)));
   end
   k = k + 1; v(k) = q; z(k) = s; z(k+1) = inf;
end
g = zeros(n,1); arg = zeros(n,1);
k = 1;
for q = 1:n
   while z(k+1) < q, k = k + 1; end
   arg(q) = v(k);
   g(q) = eps2*(q - v(k))^2 + f(v(k));
end
end

function m = coverMask(P, H, W, w)
m = false(H, W);
for q = 1:size(P,1)
   c = P(q,1); r0 = round(P(q,2));
   if c < 1 || c > W, continue; end
   m(max(1,r0-w):min(H,r0+w), c) = true;
end
end

function CEN = kmeansR(X, K, restarts)
rng(11);
n = size(X,1);
if n > 40000, X = X(randperm(n, 40000), :); n = size(X,1); end
if n < K, K = max(1,n); end
bestI = inf; CEN = zeros(K,3);
for rr = 1:restarts
   C = zeros(K,3); C(1,:) = X(randi(n),:);
   for k = 2:K
      dd = min(sqdist(C(1:k-1,:), X), [], 1); d2 = max(dd(:),0);
      if sum(d2) <= 0, C(k,:) = X(randi(n),:); continue; end
      cdf = cumsum(d2)/sum(d2);
      C(k,:) = X(find(rand <= cdf, 1), :);
   end
   lab = ones(n,1);
   for it = 1:50
      Dm = sqdist(C, X); [~, lab] = min(Dm, [], 1); lab = lab(:);
      for k = 1:K
         m = lab==k; if any(m), C(k,:) = mean(X(m,:),1); end
      end
   end
   Dm = sqdist(C, X); inr = 0;
   for k = 1:K, m = lab==k; if any(m), inr = inr + sum(Dm(k,m)); end; end
   if inr < bestI, bestI = inr; CEN = C; end
end
end

function D = sqdist(C, X)
K = size(C,1); N = size(X,1); D = zeros(K,N);
for k = 1:K
   D(k,:) = sum((X - C(k,:)).^2, 2)';
end
end

function v = getf(s,f,d), if isfield(s,f), v = s.(f); else, v = d; end, end
