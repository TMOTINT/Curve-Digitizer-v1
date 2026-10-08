function [sel, info] = validate_paths(g, ch, crange, rowsG, rowsD, circ)
%VALIDATE_PATHS  用与提取无关的独立证据，在两条候选路径间择优
%   证据优先级：① 圆形数据标记中心（imfindcircles，真值） ② 误差棒中点 ③ 墨迹粗糙度
%   g,ch: 亮度/色度 (0..1)；crange: 列向量；rowsG/rowsD: 两条路径在该列范围的行
%   circ: N×2 [列 行] 标记中心（可空）
%   返回 sel='G'|'D'，info.ev 用了哪种证据，info.errG/errD 平均误差（越小越好）
info = struct('ev','none','errG',NaN,'errD',NaN);
sel = 'D';
n = numel(crange);
if n < 10, return; end
vG = rowsG(:)'; vD = rowsD(:)'; H = size(g,1);
% ① 圆标记：真值最硬
if ~isempty(circ)
   eG = []; eD = [];
   for k = 1:size(circ,1)
      c = round(circ(k,1)); r = circ(k,2);
      j = round(c - crange(1) + 1);
      if j < 1 || j > n, continue; end
      if ~isscalar(vG(j)) || ~isscalar(vD(j)), continue; end
      f1 = isfinite(vG(j)); f2 = isfinite(vD(j));
      if ~(f1 && f2), continue; end
      if abs(vG(j)-r) > 55 && abs(vD(j)-r) > 55, continue; end
      eG(end+1) = abs(vG(j)-r); eD(end+1) = abs(vD(j)-r); %#ok<AGROW>
   end
   if numel(eG) >= 3
      info.ev = 'circle'; info.errG = mean(eG); info.errD = mean(eD);
      if info.errG < info.errD, sel = 'G'; end
      return;
   end
end
% ② 误差棒中点：竖直长笔画关于真实值对称
eG = []; eD = [];
for j = 1:n
   c = crange(j);
   if ~isfinite(vG(j)), continue; end
   r0 = round(vG(j)); a = max(1,r0-70); b = min(H,r0+70);
   col = max(1-g(a:b,c), ch(a:b,c)) > 0.30;
   idx = find(col); if isempty(idx), continue; end
   b0 = idx(1); p = idx(1); segs = {};
   for q = 2:numel(idx)
      if idx(q) == p+1, p = idx(q); else, segs{end+1} = [b0 p]; b0 = idx(q); p = idx(q); end %#ok<AGROW>
   end
   segs{end+1} = [b0 p];
   for q = 1:numel(segs)
      h = segs{q}(2)-segs{q}(1)+1;
      if h < 25, continue; end
      mid = a + mean(segs{q}) - 1;
      if abs(mid - vG(j)) > 70, continue; end
      eG(end+1) = abs(vG(j)-mid); eD(end+1) = abs(vD(j)-mid); %#ok<AGROW>
   end
end
if numel(eG) >= 5
   info.ev = 'ebar'; info.errG = mean(eG); info.errD = mean(eD);
   if info.errG < info.errD, sel = 'G'; end
   return;
end
% ③ 无标记无误差棒：比"粗糙度是否与墨迹中心线一致"（被抹平的路径会偏小）
cen = nan(1,n);
for j = 1:n
   c = crange(j);
   if ~isfinite(vG(j)), continue; end
   r0 = round(vG(j)); a = max(1,r0-6); b = min(H,r0+6);
   w = max(0, max(1-g(a:b,c), ch(a:b,c)) - 0.12);
   if sum(w) > 0, cen(j) = sum((a:b)'.*w)/sum(w); end
end
rc = rough(cen); rg = rough(vG); rd = rough(vD);
info.ev = 'rough'; info.errG = abs(rg-rc); info.errD = abs(rd-rc);
if info.errG < info.errD, sel = 'G'; end
if ~isfinite(info.errG) || ~isfinite(info.errD), sel = 'D'; end
end
function r = rough(v)
v = v(isfinite(v)); r = NaN;
if numel(v) > 5, r = prctile(abs(diff(v,2)), 90); end
end
