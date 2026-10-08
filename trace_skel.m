function C = trace_skel(I, fr, rg, nExpect, opt)
%TRACE_SKEL  结构法曲线提取（不依赖颜色区分曲线）
%
%   针对"误差棒 / 散点 / 虚线 / 重叠曲线 / 颜色相近"的干扰：
%   ① 墨迹掩膜(亮度+色度)                 —— 与"是哪条曲线"无关
%   ② 只保留横向跨幅 >= minSpan*图宽 的连通域 —— 曲线留下；
%      虚线单段、图例样线、文字、孤立散点、误差棒帽子全部丢弃
%   ③ 骨架化 -> 1 px 中心线               —— 标记圆点不再造成偏移
%   ④ 剪枝：贴路口的短自由分支 = 误差棒两截 —— 删除
%   ⑤ 多列播种 + 中位斜率预测 + 自适应门限跟踪
%   ⑥ 未认领骨架二次回收（救回被别的结构盖住的一段）
%   ⑦ ±6 px 对称窗口墨量质心 -> 亚像素
%   颜色不参与分离，只在导出时作为 core RGB 记录。
if nargin < 5, opt = struct(); end
dbg = getf3(opt,'debug',false);
[sk, rowOf, info] = skel_prep(I, fr, opt);
I = double(I); [H,W,~] = size(I);
top = info.top; bot = info.bot; lft = info.lft; rgt = info.rgt;
g = info.g; ch = info.ch;
wDark = getf3(opt,'wDark',6);
seedF = getf3(opt,'seedF',[0.95 0.88 0.80 0.70 0.58 0.46 0.30 0.18 0.08]);

tracks = {};
manualSeeds = getf3(opt,'seeds',[]);
if ~isempty(manualSeeds)
   for k = 1:size(manualSeeds,1)
      cS = max(1,min(W,round(manualSeeds(k,1))));
      rS = max(1,min(H,round(manualSeeds(k,2))));
      rr = rowOf{cS};
      if ~isempty(rr), [~, j] = min(abs(rr - rS)); rS = rr(j); end
      [cs, rs] = walkSkeleton(rowOf, cS, rS, top, bot, lft+2, rgt-2, g, wDark);
      if numel(cs) >= 0.05*(rgt-lft), tracks{end+1} = [cs(:) rs(:)]; end %#ok<AGROW>
   end
end
for f = seedF
   if ~isempty(manualSeeds) && getf3(opt,'seedsOnly',false), break; end
   cS = round(lft + f*(rgt-lft));
   if cS < 1 || cS > W, continue; end
   rows = rowOf{cS};
   if numel(rows) < 2, continue; end
   if numel(rows) > nExpect
      sc = zeros(numel(rows),1);
      for k = 1:numel(rows), sc(k) = 1 - g(max(1,min(H,round(rows(k)))), cS); end
      [~, o] = sort(sc,'descend'); rows = sort(rows(o(1:nExpect)));
   end
   for k = 1:numel(rows)
      [cs, rs] = walkSkeleton(rowOf, cS, rows(k), top, bot, lft+2, rgt-2, g, wDark);
      if numel(cs) < 0.10*(rgt-lft), continue; end
      tracks{end+1} = [cs(:) rs(:)]; %#ok<AGROW>
   end
end
if isfield(opt,'extraTracks') && ~isempty(opt.extraTracks)
   for k = 1:numel(opt.extraTracks)
      t = opt.extraTracks{k};
      if size(t,1) >= 30, tracks{end+1} = [t(:,1) t(:,2)]; end %#ok<AGROW>
   end
end
if isempty(tracks), C = emptyC(); return; end
if dbg, fprintf('  [dbg] pass1(+外部) %d 条\n', numel(tracks)); end
reps = mergeTracks(tracks, inf, W);
reps = cleanReps(reps, W, H);

% ---- pass2：未被认领的骨架 -> 再走一遍 ----
claimed = false(H,W);
for k = 1:numel(reps)
   for j = 1:size(reps{k},1)
      r0 = round(reps{k}(j,2)); lo = max(1,r0-6); hi = min(H,r0+6);
      claimed(lo:hi, reps{k}(j,1)) = true;
   end
end
rest = bwareaopen(sk & ~claimed, 40);
CC2 = bwlabel(rest, 8);
st2 = regionprops(CC2, 'BoundingBox', 'PixelIdxList');
extra = {};
for k = 1:numel(st2)
   if st2(k).BoundingBox(3) < 60, continue; end
   [r2, c2] = ind2sub([H W], st2(k).PixelIdxList);
   [~, o] = sort(c2); c2 = c2(o); r2 = r2(o);
   cSeed = c2(max(1, round(0.85*numel(c2))));
   rsSeed = unique(r2(c2 == cSeed));
   for q = 1:min(numel(rsSeed), nExpect)
      [cs3, rs3] = walkSkeleton(rowOf, cSeed, rsSeed(q), top, bot, lft+2, rgt-2, g, wDark);
      if numel(cs3) < 40, continue; end
      extra{end+1} = [cs3(:) rs3(:)]; %#ok<AGROW>
   end
end
if dbg, fprintf('  [dbg] pass2 补 %d 条\n', numel(extra)); end
reps = mergeTracks([reps, extra], nExpect, W);
reps = cleanReps(reps, W, H);

% ---- 亚像素细化 + 输出 ----
C = emptyC();
for k = 1:numel(reps)
   cs = reps{k}(:,1); rs = reps{k}(:,2); rs2 = rs;   % cleanReps 已保证 cs 为正整数且在 [1,W]
   for j = 1:numel(cs)
      c = cs(j); r0 = round(rs(j)); lo = max(1,r0-6); hi = min(H,r0+6);
      w = max(0, max(1-g(lo:hi,c), ch(lo:hi,c)) - 0.12);
      if sum(w) > 0, rs2(j) = sum((lo:hi)'.*w)/sum(w); end
   end
   X = (cs - fr(3))*(rg(2)-rg(1))/(fr(4)-fr(3)) + rg(1);
   Y = rg(4) - (rs2 - fr(1))*(rg(4)-rg(3))/(fr(2)-fr(1));
   jm = round(median(1:numel(cs))); jj = max(1,jm-60):min(numel(cs),jm+60);
   core = zeros(1,3);
   for j = jj, core = core + reshape(I(max(1,min(H,round(rs2(j)))), cs(j), :),1,3); end
   core = core/numel(jj);
   C(end+1) = struct('X',X,'Y',Y,'px',cs,'py',rs2, ...
      'cover', numel(cs)/(max(cs)-min(cs)+1), ...
      'dark', median(1-g(sub2ind([H W], min(max(round(rs2),1),H), cs))), 'core', core); %#ok<AGROW>
end
end

function reps = cleanReps(reps, W, H)
%CLEANREPS  净化轨迹：去掉非法点；列/行必须是 [1,W]/[1,H] 内的正整数
if nargin < 3 || isempty(H), H = inf; end
%   sub2ind(..., cs) 的 cs 是第 2 个索引参数，一旦出现 0/负数/非整数，
%   MATLAB 报的正是"位置 2 处的索引无效。数组索引必须为正整数或逻辑值"。
for k = 1:numel(reps)
   v = reps{k};
   if isempty(v), reps{k} = zeros(0,2); continue; end
   v = v(isfinite(v(:,1)) & isfinite(v(:,2)), :);
   v(:,1) = min(max(round(v(:,1)), 1), W);
   v(:,2) = min(max(round(v(:,2)), 1), H);
   [~, iu] = unique(v(:,1), 'first');
   reps{k} = v(sort(iu), :);
end
reps = reps(~cellfun(@isempty, reps));
end

function C = emptyC()
C = struct('X',{},'Y',{},'px',{},'py',{},'cover',{},'dark',{},'core',{});
end
function v = getf3(s,f,d), if isfield(s,f), v = s.(f); else, v = d; end, end

function reps = mergeTracks(tracks, nmax, W)
% tracks: cell of Nx2 [col row]；返回 cell of Nx2（按列升序）。并按重叠/端到端并集合并。
if isempty(tracks), reps = {}; return; end
tracks = cleanReps(tracks, W, []);   % 必须先净化：下面 pad(k, t(:,1)) 用的是"第 2 个索引"，
                                     % 列一旦是非整数/越界就会报"位置 2 处的索引无效"
if isempty(tracks), reps = {}; return; end
nT = numel(tracks);
pad = nan(nT, W);
for k = 1:nT
   t = tracks{k}; t = t(~isnan(t(:,1)), :);
   pad(k, t(:,1)) = t(:,2);
   tracks{k} = t;
end
alive = true(1,nT); reps = {}; used = cell(1,0);
while any(alive)
   idx = find(alive); cnt = sum(~isnan(pad(idx,:)), 2);
   [~, bi] = max(cnt); a = idx(bi); A = pad(a,:); alive(a) = false;
   changed = true;
   while changed
      changed = false;
      for b = idx
         if ~alive(b), continue; end
         B = pad(b,:); common = ~isnan(A) & ~isnan(B); ok = false;
         if sum(common) >= 25
            if mean(abs(A(common)-B(common)) < 7) > 0.6, ok = true; end
         else
            ia = find(~isnan(A)); ib = find(~isnan(B));
            if ~isempty(ia) && ~isempty(ib)
               if max(ia) < min(ib), gap = min(ib)-max(ia); dr = abs(A(max(ia))-B(min(ib)));
               elseif max(ib) < min(ia), gap = min(ia)-max(ib); dr = abs(B(max(ib))-A(min(ia)));
               else, gap = 1; dr = 0; end
               if gap <= 220 && dr < 45, ok = true; end
            end
         end
         if ok, fill = isnan(A) & ~isnan(B); A(fill) = B(fill); alive(b) = false; changed = true; end
      end
   end
   cc = find(~isnan(A));
   reps{end+1} = [cc(:) A(cc)']; %#ok<AGROW>
end
n = cellfun(@(t) size(t,1), reps);
[~, ord] = sort(n,'descend');
if isfinite(nmax), ord = ord(1:min(numel(ord), nmax)); end
reps = reps(ord);
mid = cellfun(@(t) t(round(size(t,1)/2),2), reps);
[~, o2] = sort(mid); reps = reps(o2);
end

function [cs, rs] = walkSkeleton(rowOf, cS, rS, top, bot, cmin, cmax, g, wDark)
% 短间隔时把搜索中心锚在"最后一次匹配到的行"（不外推），V 形急拐不会甩飞预测；
% 只有连续 >=5 列没墨才切到中位斜率外推。
[H,~] = size(g);
cs = cS; rs = rS;
for dir = [-1 1]
   c = cS; rlast = rS; clast = cS; miss = 0; hc = cS; hr = rS;
   while true
      c = c + dir;
      if c < cmin || c > cmax, break; end
      slope = 0;
      if numel(hc) >= 6
         k = max(1, numel(hc)-11);
         dc = hc(end) - hc(k); dr = hr(end) - hr(k);
         if dc ~= 0, slope = dr/dc; end
      end
      if miss >= 5, rp = rlast + slope*(c - clast); else, rp = rlast; end
      gate = 16 + min(miss*6, 64);
      rr = rowOf{c};
      if ~isempty(rr)
         d = abs(rr - rp);
         dk = 1 - g(max(1,min(H,round(rr))), c);
         [~, j] = min(d - wDark*dk(:)');
         if d(j) <= gate
            rlast = rr(j); clast = c; miss = 0;
            hc(end+1) = c; hr(end+1) = rlast; %#ok<AGROW>
            if numel(hc) > 240, hc = hc(end-239:end); hr = hr(end-239:end); end
            cs(end+1) = c; rs(end+1) = rlast; %#ok<AGROW>   % 只记真实命中
         else
            miss = miss + 1;
         end
      else
         miss = miss + 1;
      end
      if miss > 40, break; end
   end
end
[cs, o] = unique(cs); rs = rs(o);
end
