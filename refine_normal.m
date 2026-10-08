
function [rs, info] = refine_normal(I, cs, rs, core, opt)
%REFINE_NORMAL  沿**法线方向**重估亚像素位置（而不是沿竖直方向取重心）
%
%   为什么必须按法线：
%     竖直取重心只在"水平直线"上严格等于中心线。笔画一斜，竖直截面的重心虽然
%     仍在中心线上，但**弯折处**（拐点、V 形底）竖直线会切到两侧不同曲率的部分，
%     重心被拉向弯内；陡段更明显。按法线采样则始终是笔画的垂直截面，无此偏置。
%
%   实现：
%     ① 由相邻点估切线 -> 法线方向 n=(nx,ny)
%     ② 在 p + s·n (s∈[-win,win]) 上用 interp2 双线性采样墨迹强度（或本线颜色似然）
%     ③ 取加权重心得偏移量，沿法线回代
%     ④ **可靠性判据**：若采样窗两端没有回落到接近 0（说明窗内外还有同色结构，
%        例如 fig3E 圆点下方的误差棒竖杆），该列不更新 —— 宁可不动，不能被拽走
if nargin < 5, opt = struct(); end
gf = @(f,d) getf(opt,f,d);
win  = gf('win', 12);
thr  = gf('endMax', 0.30);     % 窗端若 > thr*峰值 认为不可靠
d = double(I); [H,W,~] = size(d);
if isempty(core)
   g = mean(d,3)/255; ch = (max(d,[],3)-min(d,[],3))/255;
   V = max(1-g, ch);
else
   P = reshape(d,[],3); PW = 255-P; v = (255-core(:))'; n2 = v*v';
   al = min(max((PW*v')/n2,0),1);
   rz = sqrt(sum((PW-al*v).^2,2));
   V = reshape(al.*exp(-(rz/gf('sigma',45)).^2), H, W);
end
n = numel(cs); rs = rs(:); moved = 0; skip = 0;
S = (-win:0.5:win)';
for q = 1:n
   c = cs(q); r = rs(q);
   q0 = max(1,q-3); q1 = min(n,q+3);
   dc = cs(q1)-cs(q0); dr = rs(q1)-rs(q0);
   if dc == 0, continue; end
   nx = -dr; ny = dc; nn = hypot(nx,ny); nx = nx/nn; ny = ny/nn;   % 法线
   X = c + S*nx; Y = r + S*ny;
   if min(X(:))<1 || max(X(:))>W || min(Y(:))<1 || max(Y(:))>H, skip=skip+1; continue; end
   v = interp2(V, X, Y, 'linear', 0);
   pk = max(v);
   if ~isfinite(pk) || pk < 0.15, skip=skip+1; continue; end
   if v(1) > thr*pk || v(end) > thr*pk, skip=skip+1; continue; end      % ④ 不可靠
   w = max(v - 0.15*pk, 0);
   if sum(w) <= 1e-6, skip=skip+1; continue; end
   off = sum(w.*S)/sum(w);
   rNew = r + off*ny;
   moved = moved + abs(rNew-r);
   rs(q) = min(max(rNew, 1), H);
end
info = struct('moved', moved, 'skip', skip, 'n', n);
end
function v = getf(s,f,d), if isfield(s,f), v=s.(f); else, v=d; end, end
