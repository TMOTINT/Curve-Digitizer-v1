function key = ocrCacheKey(I, opts)
%OCRCACHEKEY  由"图像内容指纹 + 关键参数"生成 OCR 缓存键。
%
%   取固定网格上的少量像素做指纹（快且稳定）。不要对整幅图求和：
%   大图上那会很慢，而缓存的意义就是省时间。

    n = size(I);
    if numel(n) < 3, n(3) = 1; end
    ys = unique(max(1, round(linspace(1, n(1), 12))));
    xs = unique(max(1, round(linspace(1, n(2), 12))));
    sub = double(I(ys, xs, :));
    fp = sum(sub(:) .* (1:numel(sub))');      % 位置加权，降低碰撞概率
    key = sprintf('%.0fx%.0fx%d_%.6g_%d_%d_%d_%d', n(1), n(2), n(3), fp, ...
        opts.scale, opts.variants, opts.pass2, opts.minCharH);
end
