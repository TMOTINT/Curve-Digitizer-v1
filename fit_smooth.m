function [Yf, info] = fit_smooth(X, Y, opt)
%FIT_SMOOTH  稳健拟合 + 异常列局部修复（用于"过数据点拟合出来的光滑曲线"）
%
%   为什么用局部：fig3B/3C/3E 的原曲线处处光滑，异常只出现在少数列
%   （实心标记点、误差棒帽、竖向长笔画）。全局平滑会把没问题的平坦段也改动，
%   还可能削掉真实的缓弯 —— 所以默认只修异常列，其余列保留原始测量值。
%
%   X,Y : 逐列坐标（可含 NaN）
%   opt.mode   : 'local'(默认) 只修异常列 | 'global' 全部用拟合肥值
%   opt.span   : 邻域点数（默认 max(31, n/40)）
%   opt.iters  : IRLS 次数（默认 3）
%   opt.k      : 异常判定倍数（默认 3.5，尺度 = MAD*1.4826）
%   opt.margin : 异常段边界的过渡列数（默认 3，避免接缝台阶）
%   info.nfix  : 被修复的列数；info.maxfix : 最大修正量；info.rms : 拟合残差
if nargin < 3, opt = struct(); end
gf = @(f,d) getf(opt,f,d);
X = X(:); Y = Y(:); Yf = Y;
ok = isfinite(X) & isfinite(Y);
x = X(ok); y = Y(ok); n = numel(y);
info = struct('rms',NaN,'outl',0,'span',NaN,'iters',0,'nfix',0,'maxfix',0,'mode','');
if n < 20, return; end
span = min(n, round(gf('span', max(31, round(n/40)))));
iters = gf('iters', 3); kq = gf('k', 3.5); margin = gf('margin', 3);
mode = gf('mode', 'local');

rw = ones(n,1); yf = y;
for it = 1:iters
   yf = loess1(x, y, span, rw);
   r = y - yf;
   s = 1.4826 * median(abs(r - median(r)));
s = max(s, 0.5);   % 同样要设下限：否则异常判定会把所有列都判成异常
   if ~(s > 0), s = max(eps, std(r)); end
   s = max(s, 0.5);   % 尺度下限(像素)：拟合越好残差越小，不设下限会把 Tukey 权重全压成 0，
                       % 带正则的最小二乘于是解出 ~0（实测整体偏移 390~816 px）。
   u = min(abs(r)/(kq*s), 1);
   rw = (1 - u.^2).^2;                       % Tukey biweight：自动降低异常列权重
end
r = y - yf;
info.rms = sqrt(mean(r.^2));
info.outl = mean(rw < 0.5); info.span = span; info.iters = iters; info.mode = mode;

if strcmpi(mode,'global')
   Yf(ok) = yf;
   info.nfix = n; info.maxfix = max(abs(r));
   return;
end
% ---- 局部模式：只替换异常段（突起/毛刺/凹陷），其余列保持原始测量值 ----
s = 1.4826 * median(abs(r - median(r)));
s = max(s, 0.5);   % 同样要设下限：否则异常判定会把所有列都判成异常
if ~(s > 0), s = max(eps, std(r)); end
bad = abs(r) > kq*s;
d = diff([0; bad; 0]);
st = find(d == 1); en = find(d == -1) - 1;
yOut = y;
for q = 1:numel(st)
   a = st(q); b = en(q);
   yOut(a:b) = yf(a:b);
   for t = 1:margin                        % 段边界线性过渡，避免台阶
      w = t/(margin+1);
      ia = a - t; ib = b + t;
      if ia >= 1, yOut(ia) = (1-w)*y(ia) + w*yf(ia); end
      if ib <= n, yOut(ib) = (1-w)*y(ib) + w*yf(ib); end
   end
end
Yf(ok) = yOut;
info.nfix = sum(bad);
if info.nfix > 0, info.maxfix = max(abs(yf(bad) - y(bad))); end
end

function yf = loess1(x, y, span, w)
n = numel(y); yf = zeros(n,1);
for i = 1:n
   d = abs(x - x(i));
   [ds, o] = sort(d);
   hh = max(ds(min(span,n)), eps);
   wt = (1 - min(ds/hh,1).^3).^3 .* w(o);   % tricube x IRLS 权重
   if sum(wt(1:span)) < 0.05*span, wt = ones(n,1); end   % 权重崩塌保护
   xi = (x(o(1:span)) - x(i)) / hh;      % 归一化到 [-1,1]：否则二次项量级 1e6，矩阵奇异
   yi = y(o(1:span)); wi = wt(1:span);
   % 用**局部线性**而不是二次：剔除缺口后 x 不再等距，二次项会在缺口附近剧烈
   % 外插（实测 fig3E 拟合后偏离 845 px）。线性不会过冲，配合 tricube 权重足够贴合。
   A = [ones(span,1), xi];
   Aw = A .* wi; b = yi .* wi;
   c = (Aw'*A + 1e-8*eye(2)) \ (Aw'*b);
   yf(i) = c(1);
end
end

function v = getf(s,f,d), if isfield(s,f), v = s.(f); else, v = d; end, end
