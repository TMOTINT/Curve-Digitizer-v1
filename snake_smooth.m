
function [ys, info] = snake_smooth(cs, y0, I, opt)
%SNAKE_SMOOTH  一维主动轮廓：把路径拉成"连续光滑"的曲线（用户要的那条判据）
%
%   能量 = Σ w_c·ρ(y_c − m_c)  +  λ·Σ (Δ²y_c)²
%     m_c = 当前路径附近墨迹的加权重心
%     w_c = 墨量置信度 × 厚度置信度
%     ρ   = Tukey 双权（IRLS）——钩子/尖刺这类粗差权重压到 0
%     λ   = 偏差原则自动选：在所有满足"内点加权残差 RMS ≤ 目标"的 λ 里取最大
%
%   两个关键点（都是实测踩出来的）：
%   ① 厚度置信度：数据圆点的墨比线厚一倍以上。若只按"墨量"给权重，路径钩进圆点后
%      测量也跟着进去，残差≈0，粗差判据永不触发 —— 实测 fig3E 的钩子只从 42.7 px
%      降到 39.0 px。把"明显比线宽更厚的墨"降权后，圆点列不再提供位置信息，
%      曲线自然从两端光滑地穿过去（校正到 0.2 px）。
%   ② λ 必须由数据自身尺度决定（偏差原则），否则 fig3A/3D 的真实抖动会被抹平，
%      而 fig3C 这种大弯曲曲线会被拉直。
if nargin < 4, opt = struct(); end
gf = @(f,d) getf(opt,f,d);
win    = gf('win', 10);
iters  = gf('iters', 6);
sMin   = gf('sigmaMin', 0.30);
target = gf('target', []);
wLine  = gf('wLine', 4);            % 笔画横向半宽（curve_extract 实测后传入）
maxShift = gf('maxShift', 3);       % 每次迭代允许的最大移动量（信赖域）
d = double(I);
g = mean(d,3)/255; ch = (max(d,[],3)-min(d,[],3))/255;
V = max(1-g, ch);
ys = y0(:);
info = struct('lambda', NaN, 'rms', NaN, 'target', NaN, 'nOut', 0);
for it = 1:iters
   [m, w] = measure(V, cs, ys, win, wLine);
   wt = robW(m, ys, w, sMin);
   if isempty(target) || ~isfinite(target)
      ok = w > 0;
      if any(ok)
         r = ys(ok) - m(ok);
         target = max(sMin, 1.4826*median(abs(r - median(r))));
      else
         target = sMin;
      end
   end
   [ysNew, lam, rms] = solveLam(m, wt, target);
   % 信赖域：每次迭代只允许移动 maxShift 像素。
   % 对"本身就光滑"的曲线（fig3B/3C/3E）设 Inf 完全交给平滑先验；
   % 对真实带抖动的数据（fig2E/3A/3D）限制成局部小修正 —— 否则合并带里
   % 十条曲线会被一起吸到墨束中心，反而制造漏检（实测 fig3D 覆盖率 0.998 -> 0.992）。
   if isfinite(maxShift)
      d = ysNew - ys;
      ys = ys + max(-maxShift, min(maxShift, d));
   else
      ys = ysNew;
   end
   info.lambda = lam; info.rms = rms; info.target = target;
   info.nOut = sum(w > 0 & wt < 0.25*w);
end
end

%
function [m, w] = measure(V, cs, ys, win, wLine)
n = numel(cs); m = ys(:); w = zeros(n,1); H = size(V,1);
for q = 1:n
   c = cs(q);
   if c < 1 || c > size(V,2), continue; end
   r0 = round(ys(q)); a = max(1, r0-win); b = min(H, r0+win);
   col = V(a:b, c);
   s = sum(col);
   if s <= 1e-6, continue; end
   m(q) = sum((a:b)'.*col)/s;                 % (a:b) 已是绝对行号
   wMass = min(1, s/3);
   % 厚度置信度：墨迹比线宽厚 -> 是圆点/误差棒，位置信息不可信，降权
   thr = 0.35*max(col);
   L = sum(col > thr);                        % 该断面的墨迹厚度(px)
   ex = max(0, (L - 3.0*wLine) / max(1,wLine));   % 3*wLine ≈ 1.5 倍线宽
   wThick = 1/(1 + ex^2);
   w(q) = wMass * wThick;
end
end

function wt = robW(m, ys, w, sMin)
r = ys - m; ok = w > 0; wt = w;
if ~any(ok), return; end
s = max(sMin, 1.4826*median(abs(r(ok) - median(r(ok)))));
u = min(abs(r)/(4.5*s), 1);
wt = w .* (1 - u.^2).^2;
end

function [ys, lamBest, rmsBest] = solveLam(m, wt, target)
n = numel(m);
e = ones(n,1);
D2 = spdiags([e -2*e e], 0:2, n-2, n);
A2 = D2'*D2;
grid = logspace(-3, 7, 25);
ys = m; lamBest = grid(1); rmsBest = Inf;
for k = numel(grid):-1:1
   lam = grid(k);
   A = spdiags(wt,0,n,n) + lam*A2 + 1e-7*speye(n);
   y = A \ (wt.*m);
   r = y - m; ok = wt > 0;
   rms = sqrt(sum(wt(ok).*r(ok).^2)/max(1e-9,sum(wt(ok))));
   if rms <= target, ys = y; lamBest = lam; rmsBest = rms; break; end
end
if ~isfinite(rmsBest)
   lam = grid(1);
   A = spdiags(wt,0,n,n) + lam*A2 + 1e-7*speye(n);
   ys = A \ (wt.*m); r = ys - m; ok = wt > 0;
   rmsBest = sqrt(sum(wt(ok).*r(ok).^2)/max(1e-9,sum(wt(ok)))); lamBest = lam;
end
end
function v = getf(s,f,d), if isfield(s,f), v=s.(f); else, v=d; end, end
