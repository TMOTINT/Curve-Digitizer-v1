function [X, Y, info] = snapPolyline(I, ax, cal, pts, opts)
%SNAPPOLYLINE  把用户"随手画的折线"吸附到真实曲线上（手描 + activecontour）
%
%   ==================== 为什么需要这条路 ====================
%   遇到"同色系 + 谷底挤成一团 + 互相交叉"的曲线族（实测 Fig.3D 就是），
%   纯自动方法无法可靠分辨：颜色一样、位置只差 2~3 px。
%   这时最可靠的是**人给拓扑、算法给精度**：
%     1) 用户在图上沿曲线随手画几笔（不必精确，差十几个像素都行）
%     2) 在折线周围的窄带里跑 activecontour，让它自己吸到线的中心
%     3) 再取亚像素重心输出
%   窄带限制是关键：不加会把轮廓吸到旁边那条曲线上。
%
%   用法:
%     [X,Y] = snapPolyline(I, ax, cal, [x1 y1; x2 y2; ...])
%     opts:  band      窄带宽度（px，默认 14）
%            iters     activecontour 迭代次数（默认 25）
%            smooth    平滑项（默认 1.2）
%            verbose   打印过程
%
%   需要 Image Processing Toolbox 的 activecontour（本机已确认可用）。
%   没有 IPT 时退化为"折线 + 三次样条"，仍然可用，精度略低。

    if nargin < 5, opts = struct(); end
    if ~isfield(opts,'band'),    opts.band = 14;   end
    if ~isfield(opts,'iters'),   opts.iters = 25;  end
    if ~isfield(opts,'smooth'),  opts.smooth = 1.2; end
    if ~isfield(opts,'verbose'), opts.verbose = false; end

    info = struct('usedAC', false, 'nIn', size(pts,1), 'nOut', 0);

    D = double(I);
    if size(D,3) == 1, D = repmat(D,1,1,3); end
    G = 0.299*D(:,:,1) + 0.587*D(:,:,2) + 0.114*D(:,:,3);
    [H, W] = size(G);

    P = double(pts);
    P(:,1) = min(max(P(:,1), 2), W-1);
    P(:,2) = min(max(P(:,2), 2), H-1);
    if size(P,1) < 2
        X = []; Y = []; return;
    end
    if size(P,1) == 2                      % 只点两点：先插值成折线
        t = linspace(0,1,40)';
        P = [P(1,1)+(P(2,1)-P(1,1))*t, P(1,2)+(P(2,2)-P(1,2))*t];
    end

    % ---- 1. 折线 -> 稠密路径 ----
    [xc, yc] = densifyPath(P);

    % ---- 2. 窄带掩膜（沿路径膨胀 band 像素）----
    band = false(H, W);
    idx = sub2ind([H W], round(yc), round(xc));
    band(idx) = true;
    if exist('imdilate','file') && exist('strel','file')
        band = imdilate(band, strel('disk', round(opts.band)));
    else
        band = dilateLocal(band, round(opts.band));
    end
    info.bandPx = nnz(band);

    % ---- 3. activecontour 吸附（只在窄带内演化）----
    mask = band;
    if exist('activecontour','file')
        try
            % 灰度归一化到 0-1：activecontour 对取值范围敏感，
            % 直接喂 0-255 会报"强度范围太小/太大"而不收敛。
            Gn = mat2grayLocal(G);
            it = opts.iters;
            mask = activecontour(Gn, band, it, 'Chan-Vese', ...
                'SmoothFactor', opts.smooth, 'ContractionBias', 0);
            mask = mask & band;            % 严格限制在窄带内
            info.usedAC = true;
        catch ME
            if opts.verbose
                fprintf('  [snap] activecontour 失败（%s），改用折线\n', ME.message);
            end
            mask = band;
        end
    end

    % ---- 4. 从吸附结果里取中心线：逐列取重心 ----
    %   用"距离图"判断哪些像素属于用户画的那条线：
    %   先对折线做距离变换，吸附结果里离折线近的像素才是同一条线。
    %   为什么不用 interp1 反查：陡段的加密路径里 x 会重复，
    %   interp1 要求样本点唯一，会直接报错（实测踩过）。
    pathMask = false(H, W);
    pathMask(sub2ind([H W], round(yc), round(xc))) = true;
    if exist('bwdist','file')
        dPath = bwdist(pathMask);
    else
        dPath = distLocal(pathMask);
    end
    near = dPath <= max(3, opts.band/2);      % 属于"用户那条线"的范围

    X = []; Y = [];
    cols = unique(round(xc));
    for c = cols(:)'
        rows = find(mask(:, c) & near(:, c));
        if isempty(rows), continue; end
        d = diff(rows); brk = find(d > 1);
        segs = {}; s = 1;
        for k = 1:numel(brk), segs{end+1} = rows(s:brk(k)); s = brk(k)+1; end %#ok<AGROW>
        segs{end+1} = rows(s:end);
        [~, bi] = max(cellfun(@numel, segs));
        seg = segs{bi}(:);
        if numel(seg) > 25, continue; end
        rw = subRowLocal2(G, c, seg);
        X(end+1,1) = c; Y(end+1,1) = rw; %#ok<AGROW>
    end

    % ---- 5. 像素 -> 数据坐标 ----
    if ~isempty(X) && nargin >= 3 && ~isempty(cal)
        Xd = cal.xFromPx(X); Yd = cal.yFromPx(Y);
        [Xd, o] = sort(Xd); Yd = Yd(o);
        X = Xd; Y = Yd;
    end
    info.nOut = numel(X);
    if opts.verbose
        fprintf('  [snap] 输入 %d 点 -> 输出 %d 点（activecontour %s）\n', ...
            info.nIn, info.nOut, ternStr(info.usedAC, '已用', '未用'));
    end
end

% ---------------------------------------------------------------------
function [xc, yc] = densifyPath(P)
%DENSIFYPATH  把折线按 1 px 间隔加密
    xc = []; yc = [];
    for k = 1:(size(P,1)-1)
        p1 = P(k,:); p2 = P(k+1,:);
        n = max(2, round(norm(p2-p1)) + 1);
        t = linspace(0,1,n)';
        xc = [xc; p1(1) + (p2(1)-p1(1))*t]; %#ok<AGROW>
        yc = [yc; p1(2) + (p2(2)-p1(2))*t]; %#ok<AGROW>
    end
end

function B = dilateLocal(A, r)
%以方形结构元膨胀（无 IPT 时的替代）
    B = A;
    for k = 1:r
        B = B | [B(2:end,:); false(1,size(B,2))] | [false(1,size(B,2)); B(1:end-1,:)] | ...
            [B(:,2:end), false(size(B,1),1)] | [false(size(B,1),1), B(:,1:end-1)];
    end
end

function G = mat2grayLocal(G)
    lo = min(G(:)); hi = max(G(:));
    if hi <= lo, G = zeros(size(G)); else, G = (G - lo) / (hi - lo); end
end

function cw = subCol(G, r, cols)
%SUBCOL  沿行方向取亚像素重心（列坐标）
    v = double(G(r, cols));
    if numel(v) < 2, cw = mean(cols); return; end
    w = max(v) - v; w = max(w, 0);
    if sum(w) <= eps, cw = mean(cols); else, cw = sum(cols(:).*w(:)) / sum(w); end
end

function D = distLocal(mask)
%DISTLOCAL  近似距离变换（无 bwdist 时的替代：逐点向外扩，直到碰到种子）
    [H, W] = size(mask);
    D = inf(H, W);
    D(mask) = 0;
    cur = mask;
    for r = 1:60
        nxt = cur | [cur(2:end,:); false(1,W)] | [false(1,W); cur(1:end-1,:)] | ...
                   [cur(:,2:end), false(H,1)] | [false(H,1), cur(:,1:end-1)];
        newly = nxt & ~cur;
        D(newly) = r;
        cur = nxt;
        if all(cur(:)), break; end
    end
end

function rw = subRowLocal2(G, c, rows)
%SUBROWLOCAL2  沿列方向取亚像素重心（行坐标）
    v = double(G(rows, c));
    if numel(v) < 2, rw = mean(rows); return; end
    w = max(v) - v; w = max(w, 0);
    if sum(w) <= eps, rw = mean(rows); else, rw = sum(rows(:).*w(:)) / sum(w); end
end

function s = ternStr(c, a, b)
    if c, s = a; else, s = b; end
end
