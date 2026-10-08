function [yg, inl] = robustLowess(x, y, span, opts)
%ROBUSTLOWESS  稳健局部加权回归（LOWESS / LOESS 的稳健版本）。
%
%   ★ 为什么用它替代全局多项式：
%   全局多项式（polyfit）是"一个模型管全区"，只要有局部污染（标记点、
%   误差棒、图例样本线）就会把整条曲线带偏 —— 实测与数据点的偏差中位
%   达 63 nm、最大 88 nm。
%   LOWESS 是"每个位置只用附近的点拟合一个低阶多项式"，局部污染只影响
%   它附近的一小段，且稳健迭代会把离群点权重压到接近 0。
%
%   用法:
%     yg = robustLowess(x, y)                      % 默认 span=0.25, 3 次稳健迭代
%     yg = robustLowess(x, y, 0.3, struct('iters',4))
%     [yg, inl] = robustLowess(x, y, span)         % inl 是内点标记
%
%   参数:
%     span   邻域宽度（占点数的比例，0~1）。越大越平滑。默认 0.25
%     opts.iters   稳健迭代次数（默认 3）
%     opts.xg      需要求值的位置（默认用排序后的 x）
%     opts.degree  局部多项式阶数（1 或 2，默认 1）
%
%   返回:
%     yg   在 opts.xg（或排序后的 x）处的拟合值
%     inl  与 y 同长度的逻辑向量，标出被当作内点的观测
%
%   依赖：MATLAB 基础功能，不需要任何工具箱。

    if nargin < 4, opts = struct(); end
    if nargin < 3 || isempty(span), span = 0.25; end

    x = x(:); y = y(:);
    ok = isfinite(x) & isfinite(y);
    x = x(ok); y = y(ok);
    if numel(x) < 4
        yg = []; inl = false(size(ok)); return;
    end

    if ~isfield(opts,'iters'),  opts.iters = 3;  end
    if ~isfield(opts,'degree'), opts.degree = 1; end
    deg = max(1, min(2, opts.degree));

    % 按 x 排序，邻域才好取
    [xs, o] = sort(x);
    ys = y(o);
    n = numel(xs);

    % 邻域点数（至少比阶数多几个）
    k = max(deg + 2, ceil(span * n));
    k = min(k, n);

    % 求值位置
    if isfield(opts,'xg') && ~isempty(opts.xg)
        xg = opts.xg(:);
    else
        xg = xs;
    end

    w = ones(n,1);          % 稳健权重，初始全 1
    yfitS = zeros(n,1);     % 在观测点上的拟合值（用于算残差）

    for it = 1:max(1,opts.iters)
        for i = 1:n
            % 以 xs(i) 为中心，取最近的 k 个点
            d = abs(xs - xs(i));
            [ds, ord] = sort(d);
            idx = ord(1:k);
            h = max(ds(k), eps);
            u = ds(1:k) / h;
            tri = (1 - u.^3).^3;          % tricube 核
            ww = tri .* w(idx);           % 乘上稳健权重
            yfitS(i) = localFit(xs(idx), ys(idx), ww, xs(i), deg);
        end
        r = ys - yfitS;
        s = median(abs(r));
        if s <= 0, break; end
        % bisquare 稳健权重
        u = min(1, abs(r) / (6*s));
        wNew = (1 - u.^2).^2;
        if max(abs(wNew - w)) < 1e-3, w = wNew; break; end
        w = wNew;
    end

    % 在求值位置上输出
    yg = zeros(numel(xg),1);
    for i = 1:numel(xg)
        d = abs(xs - xg(i));
        [ds, ord] = sort(d);
        idx = ord(1:k);
        h = max(ds(k), eps);
        u = ds(1:k) / h;
        tri = (1 - u.^3).^3;
        ww = tri .* w(idx);
        yg(i) = localFit(xs(idx), ys(idx), ww, xg(i), deg);
    end

    % 内点判定：残差不超过 6 倍中位绝对偏差
    inlSorted = abs(ys - yfitS) <= 6*max(s, eps);
    inl = false(size(ok));
    tmp = false(numel(o),1);
    tmp(o) = inlSorted;
    inl(ok) = tmp;
end

% =====================================================================
function y0 = localFit(x, y, w, x0, deg)
%LOCALFIT  加权局部多项式在 x0 处的取值（手写加权最小二乘，避免依赖）
    if deg >= 2
        A = [ones(numel(x),1), (x-x0), (x-x0).^2];
    else
        A = [ones(numel(x),1), (x-x0)];
    end
    sw = sqrt(max(w,0));
    Aw = A .* sw;
    yw = y .* sw;
    % 求解加权最小二乘；奇异时退化为加权均值
    if rcond(Aw'*Aw) < 1e-12
        y0 = sum(w.*y) / max(sum(w), eps);
        return;
    end
    c = (Aw'*Aw) \ (Aw'*yw);
    y0 = c(1);
end
