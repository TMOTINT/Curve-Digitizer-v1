
function [cs, rs, info] = snap_to_color(I, cs, rs, core, opt)
%SNAP_TO_COLOR  逐列把路径重新吸附到"本曲线颜色"的墨峰上（吸收圆点/粘连造成的偏离）
%   与 DP 的区别：DP 是全局一次成型的折中；这里是逐列独立地找本颜色的墨峰，
%   因此不会为了"少拐弯"而抄近路穿过尖峰（fig3F 的病根），
%   也不会因为窗口太窄而卡在圆点边缘（只要窗口够大就会回到圆心=曲线位置）。
%
%   窗口 win 很关键：
%     · 平滑拟合线(fig3B/3C/3E)：win 取 ~1.5 线宽即可，靠 snake_smooth 保证光滑
%     · 密集锯齿(fig3F)：win 要大到能跨过尖峰（实测 150 px），靠颜色区分两条线
if nargin < 5, opt = struct(); end
gf = @(f,d) getf(opt,f,d);
win = gf('win', 12); iters = gf('iters', 2); sigma = gf('sigma', 45);
d = double(I); [H,W,~] = size(d);
P = reshape(d, [], 3); PW = 255 - P;
v = (255 - core(:))'; n2 = v*v';
al = min(max((PW*v')/n2, 0), 1);
rz = sqrt(sum((PW - al*v).^2, 2));
L = reshape(al .* exp(-(rz/sigma).^2), H, W);
info = struct('moved', 0);
for it = 1:iters
   rsNew = rs;
   for q = 1:numel(cs)
      c = cs(q); r0 = round(rs(q));
      a = max(1, r0-win); b = min(H, r0+win);
      col = L(a:b, c);
      [pk, j] = max(col);
      if ~isfinite(pk) || pk < 0.15, continue; end
      p1 = j; p2 = j;
      while p1 > 1 && col(p1-1) > 0.35*pk, p1 = p1 - 1; end
      while p2 < numel(col) && col(p2+1) > 0.35*pk, p2 = p2 + 1; end
      w = col(p1:p2);
      if sum(w) <= 0, continue; end
      rsNew(q) = a + sum((p1:p2)'.*w)/sum(w) - 1;
   end
   info.moved = info.moved + sum(abs(rsNew - rs) > 1);
   rs = min(max(rsNew, 1), H);
end
end
function v = getf(s,f,d), if isfield(s,f), v=s.(f); else, v=d; end, end
