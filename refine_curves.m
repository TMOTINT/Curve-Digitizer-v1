function CR = refine_curves(I, fr, guides, cores, opt)
%REFINE_CURVES  逐条精确化：非交叉硬带 + 二阶全局 DP + 本曲线颜色亚像素 + 自动择优
%
%   ① 身份/拓扑来自 guides（骨架+混色并集），按行从上到下排序；
%   ② 第 k 条的逐列硬带 = 与相邻两条引导线的中线之间（每侧至少留 minHalf 活动空间，
%      汇聚处自动收窄），这就是"曲线不交叉"先验，防止串到只隔几 px 的邻线；
%   ③ 带内跑二阶（曲率惩罚）全局 DP，代价含本曲线颜色的混色匹配；
%      惩罚按**该条引导线自身粗糙度**自适应：越抖（p90|二阶差分| 越大）惩罚越小，
%      这样高振荡曲线不会被抹平，平滑曲线仍能被压掉逐列抖动；
%   ④ D P 只负责选分支，精度交给逐列 ±3px 的混色加权重心（不平滑）；
%   ⑤ 最后在"引导线"与"DP"之间，按"离该列墨迹重心多近"逐条自动择优并记录 src。
%
%   opt: pad(4) minHalf(18)
if nargin < 5, opt = struct(); end
gf = @(f,d) getfld(opt,f,d);
pad = gf('pad',4);
rTop = max(2, round(fr(1))); rBot = min(size(I,1)-1, round(fr(2)));
W = size(I,2); n = numel(guides);
G = nan(n, W);
for k = 1:n
   t = guides{k}; t = t(~isnan(t(:,1)), :);
   G(k, t(:,1)) = t(:,2);
end
for k = 1:n
   v = G(k,:); idx = find(~isnan(v));
   if isempty(idx), continue; end
   vv = interp1(idx, v(idx), 1:W, 'nearest', 'extrap');
   if idx(1) > 1, vv(1:idx(1)-1) = NaN; end
   if idx(end) < W, vv(idx(end)+1:W) = NaN; end
   fin = isfinite(vv);
   vv(fin) = min(max(vv(fin), rTop), rBot);
   G(k,:) = vv;
end
I = double(I); H = size(I,1);
g = mean(I,3)/255; ch = (max(I,[],3)-min(I,[],3))/255; inkv = max(1-g, ch);
% ---- 一次性检测圆形数据标记（独立真值证据）----
circ = zeros(0,2);
try
   cL0 = max(1, round(fr(3))+2); cR0 = min(W, round(fr(4))-2);
   sub = uint8(255*g(rTop:rBot, cL0:cR0));
   [cc, ~] = imfindcircles(sub, [9 34], 'ObjectPolarity','dark', 'Sensitivity',0.90);
   if ~isempty(cc), circ = [round(cc(:,1))+cL0-1, round(cc(:,2))+rTop-1]; end
catch
   circ = zeros(0,2);
end
CR = struct('px',{},'py',{},'span',{},'src',{},'sg',{},'sd',{},'art',{});
for k = 1:n
   if all(isnan(G(k,:))), continue; end
   up = rTop*ones(1,W); dn = rBot*ones(1,W);
   if k > 1 && ~all(isnan(G(k-1,:))), up = (G(k-1,:) + G(k,:))/2; end
   if k < n && ~all(isnan(G(k+1,:))), dn = (G(k,:) + G(k+1,:))/2; end
   half = gf('minHalf',18);
   up = min(up, G(k,:) - half);
   dn = max(dn, G(k,:) + half);
   lo = up + pad; hi = dn - pad;
   thin = (hi - lo) < 8;
   lo(thin) = G(k,thin) - 4; hi(thin) = G(k,thin) + 4;
   lo = min(max(lo, rTop), rBot); hi = min(max(hi, rTop), rBot);
   ok = hi > lo;
   lo(~ok) = max(rTop, G(k,~ok) - 4); hi(~ok) = min(rBot, G(k,~ok) + 4);
   % ---- 自适应惩罚 + 自适应最大步长（关键：振荡曲线的斜率会超过固定步长）----
   vel = G(k, isfinite(G(k,:)));
   rough = 1; ms = 8;
   if numel(vel) > 5
      rough = max(1, prctile(abs(diff(vel, 2)), 90));          % 曲率量级
      ms = max(6, min(16, ceil(prctile(abs(diff(vel)), 95)) + 3));  % 斜率量级
   end
   lam2 = max(0.008, min(0.100, 0.10 / rough));
   lam1 = 0.4 * lam2;
   % 逐图门控：只有登记在 opt.followTags 里的图才走"直接跟随"（不再用全局斜率阈值，
   % 那会误抓 fig2E）。跟随覆盖不足 80% 时自动退回 DP，绝不交残缺轨迹。
   followTag = gf('tag', '');
   % 跟随器默认关闭（followTags 为空）。原因：probe 仍有索引越界警告、覆盖只到 73%，
   % 未过 80% 门槛；修好这两点后把 'fig3F' 加进 followTags 即可启用。
   useFollow = any(strcmp(followTag, gf('followTags', {})));
   if useFollow
      % 抖动剧烈的曲线：DP 的曲率惩罚会把真实起伏抹平（fig3F 实测 -57 -> -45）。
      % 改用"只用本曲线颜色的墨，逐列照原样跟随"，不做任何平滑。
      [cs, rs] = follow_ink(I, fr, G(k,:), cores{k}, struct());
      need = 0.8 * nnz(isfinite(G(k,:)));
      if numel(cs) < max(20, need)
         fprintf('FALLBACK [%s C%d] cover %d/%d -> DP\n', followTag, k, numel(cs), round(need));
         cs = [];
      else
         fprintf('FOLLOW   [%s C%d] %d cols cover %.0f%%\n', followTag, k, numel(cs), 100*numel(cs)/need);
      end
   else
      cs = [];
   end
   if isempty(cs)
      [cs, rs] = dp_trace(I, fr, G(k,:), struct('core', cores{k}, 'lo', lo, 'hi', hi, ...
                 'band', 60, 'lam1', lam1, 'lam2', lam2, 'maxStep', ms, 'wguide', gf('wguide',0.20)));
   end
   if isempty(cs), continue; end
   % ---- 误差棒感知的逐列测量（这是 fig3B/3C/3E 锯齿的根源）----
   % 误差棒是竖直长笔画，且**关于数据点对称** -> 段中点就是数据点，比质心更准；
   % 端部短横线（cap）落在远处，本来就在 ±3px 窗口之外。
   % 普通列仍用本曲线颜色的混色加权重心（亚像素、不平滑）。
   core = reshape(cores{k},1,3); u = 255 - core; n2 = u*u';
   inkb = inkv > 0.30;   % 不用全图颜色投影：它要 ~300MB 临时数组，撤掉（也更稳）
   chromaCore = max(core) - min(core);   % 核心色的彩度：黑白 ≈ 0
   nQ = numel(cs);
   rl = zeros(nQ,1); rt = rl; rb = rl;
   for q = 1:nQ
      c = cs(q); r0 = max(1, min(H, round(rs(q))));
      a = max(1, r0-90); b = min(H, r0+90);
      on = inkb(a:b, c);
      i0 = r0 - a + 1;
      if i0 >= 1 && i0 <= numel(on) && on(i0)
         p1 = i0; p2 = i0;
         while p1 > 1 && on(p1-1), p1 = p1 - 1; end
         while p2 < numel(on) && on(p2+1), p2 = p2 + 1; end
         rt(q) = a + p1 - 1; rb(q) = a + p2 - 1; rl(q) = p2 - p1 + 1;
      else
         rt(q) = r0; rb(q) = r0; rl(q) = 1;
      end
   end
   th = rl(rl >= 2);
   thick = 8;
   if ~isempty(th), thick = max(2, prctile(th, 40)); end   % 线宽的稳健估计
   rs2 = rs;
   for q = 1:nQ
      c = cs(q);
      useMid = false;
      % 只有**彩色**曲线才可能有误差棒；fig2E 是黑色均值线（无误差棒），
      % 若对它启用该判据会因黑线与灰散点黏连而拉低精度（99.2% -> 96.6%）
      if chromaCore > 40 && rl(q) > 2.2*thick && rl(q) < 8*thick
         % 必须是"窄"竖直笔画才是误差棒；与散点/别的线黏成的大块要走质心
         % （否则 fig2E 的黑均值线会被灰散点带偏：99.2% -> 94.0%）
         rrs = round(linspace(rt(q)+0.2*rl(q), rb(q)-0.2*rl(q), 3));
         hw = zeros(1,3);
         for z = 1:3, hw(z) = hwidth(inkb, c, rrs(z), W); end
         if max(hw) <= 1.8*thick, useMid = true; end   % 误差棒与曲线同笔宽；黏连大块会远大于此
      end
      if useMid
         rs2(q) = (rt(q) + rb(q)) / 2;      % 误差棒列：段中点即数据点
      else
         r0 = round(rs(q)); a = max(1,r0-3); b = min(H,r0+3);
         if n2 < 1e3
            w = max(0, 1 - g(a:b,c) - 0.12);
         else
            P = reshape(I(a:b,c,:), [], 3);
            al = min(max(((255-P)*u')/n2, 0), 1);
            rz = sqrt(sum((255-P-al*u).^2, 2));
            w = al .* exp(-(rz/40).^2);
            if sum(w) < 0.2*numel(w), w = max(0, inkv(a:b,c) - 0.12); end
         end
         if sum(w) > 0, rs2(q) = sum((a:b)'.*w)/sum(w); end
      end
   end
   cs = cs(:); rs2 = min(max(rs2(:), rTop), rBot);
   % ---- 可选：剔除"大点/带短横线的误差棒"所在列的测量 ----
   % 判据用**水平墨宽**：填充标记点/短横线宽 20~35px，而线宽仅 ~9px；
   % 陡峭曲线段虽然竖直方向长，水平方向仍只有线宽 -> 不会被误伤。
   % 这些列置 NaN（= 该列没有可用测量），由随后的一次平滑拟合补上。
   nArt = [0 0];
   if gf('dropArtifacts', false)
      % 判据必须**方向无关**：不能用"水平墨宽"——近水平的曲线其水平连通长度
      % 就是曲线自身长度（几百 px），会被整条误判成"大点"（实测 fig3C 剔掉 87.6%）。
      % 改用「局部墨量」（邻域内的墨像素数）：线与标记点在任何倾角下都可区分，
      % 且阈值用**本曲线自身的中位墨量**自适应，不依赖绝对线宽。
      nQ = numel(cs);
      % 用**距离变换**量"该点的墨迹半厚"：
      %   普通线 -> 半厚 = 线宽/2（全曲线一致）
      %   填充标记点 -> 半厚 ≈ 标记点半径（大好几倍）
      %   相邻曲线/陡峭段都不会改变"本点到最近背景的距离" -> 天然不受干扰
      dtv = bwdist(~inkb);
      dq = zeros(1,nQ); rlv = zeros(1,nQ);
      for q = 1:nQ
         r0 = min(max(round(rs2(q)),1),H);
         dq(q) = dtv(r0, cs(q));
         rlv(q) = vspan(inkb, cs(q), r0);
      end
      dqm = dq(dq > 0);
      thick = 8;
      if ~isempty(dqm), thick = 2*median(dqm); end   % 稳健线宽
      bad1 = dq > 1.1*thick;                          % 半厚 > 2.2x 半线宽 -> 标记点/短横线
      bad2 = false(1,nQ);                             % 短竖线：竖直墨长异常且**孤立**
      for q = 1:nQ
         if rlv(q) <= 2.5*thick, continue; end
         lo = max(1,q-3); hi = min(nQ,q+3);
         nb = rlv([lo:q-1, q+1:hi]);
         if isempty(nb) || median(nb) < 1.5*thick, bad2(q) = true; end
      end
      bad = bad1 | bad2;
      rs2(bad) = NaN;
      nArt = [sum(bad1), sum(bad2)];
   end   % ---- 近竖直段：单列里曲线跨很多像素，一个点表示不了 -> 补上/中/下三点 ----
   % ---- 用独立证据在"引导线"与"DP"之间择优（圆标记 -> 误差棒中点 -> 粗糙度）----
   cA = min(cs); cB = max(cs);
   dpRow = nan(1,W); dpRow(cs) = rs2;
   rowsG = G(k, cA:cB); rowsD = dpRow(cA:cB);
   [sel, vin] = validate_paths(g, ch, cA:cB, rowsG, rowsD, circ);
   if strcmp(sel,'G')
      keep = isfinite(rowsG)';
      cc3 = (cA:cB)'; cc3 = cc3(keep); rr3 = rowsG(keep)';
      src = ['guide-' vin.ev];
   else
      cc3 = cs; rr3 = rs2; src = ['dp-' vin.ev];
   end
   thrV = gf('vfill', Inf);
   if isinf(thrV)
      cc4 = cc3; rr4 = rr3;                       % 关闭时直接跳过，不做无用的逐点扫描
   else
      [cc4, rr4] = vertFill(cc3, rr3, g, ch, H, thrV);
   end
   CR(end+1) = struct('px',cc4,'py',rr4,'span',[min(cc3) max(cc3)], ...
      'src',src,'sg',vin.errG,'sd',vin.errD,'art',nArt); %#ok<AGROW>
end
end

function L = vspan(inkb, c, r)
%VSPAN  某点所在墨迹的竖直连通长度（用于识别误差棒这类短竖线）
L = 0;
if r < 1 || r > size(inkb,1) || c < 1 || c > size(inkb,2) || ~inkb(r,c), return; end
a = r; b = r;
while a > 1 && inkb(a-1,c), a = a - 1; end
while b < size(inkb,1) && inkb(b+1,c), b = b + 1; end
L = b - a + 1;
end

function w = hwidth(inkb, c, r, W)
%HWIDTH  某点所在墨迹的水平连通长度（用来判"竖直窄笔画" vs "黏连大块"）
w = 0;
if r < 1 || r > size(inkb,1) || c < 1 || c > W || ~inkb(r,c), return; end
a = c; b = c;
while a > 1 && inkb(r, a-1), a = a - 1; end
while b < W && inkb(r, b+1), b = b + 1; end
w = b - a + 1;
end

function [cx, ry] = vertFill(cs, rs, g, ch, H, thr)
%VERTFILL  对"墨迹竖直跨度 > thr"的列，用上/中/下三点表示该列（陡段本来就是多值的）
cx = zeros(0,1); ry = zeros(0,1);
inkv = max(1-g, ch);
for j = 1:numel(cs)
   c = cs(j); r0 = max(1, min(H, round(rs(j))));
   a = max(1, r0-140); b = min(H, r0+140);
   on = inkv(a:b, c) > 0.30;
   % TODO 启用前必须加"竖直笔画"判据：该 run 在各行的水平跨度必须 <= 1.6*线宽，
   %      否则会把相接的散点/虚线/误差棒当成陡段（实测 fig2E 的 Y 范围被拉到 -36..209）。
   rr = r0 - a + 1;
   i1 = rr; i2 = rr;
   if rr >= 1 && rr <= numel(on) && on(rr)
      while i1 > 1 && on(i1-1), i1 = i1 - 1; end
      while i2 < numel(on) && on(i2+1), i2 = i2 + 1; end
   end
   top = a + i1 - 1; bot = a + i2 - 1;
   if (bot - top) > thr
      cx = [cx; c; c; c]; ry = [ry; top; rs(j); bot]; %#ok<AGROW>
   else
      cx = [cx; c]; ry = [ry; rs(j)]; %#ok<AGROW>
   end
end
end

function v = getfld(s,f,d), if isfield(s,f), v = s.(f); else, v = d; end, end
