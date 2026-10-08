function cand = colorCurves(I, ax, opts)
%COLORCURVES  自动按颜色分离出图中的多条曲线，返回候选列表。
%
%   用途：论文图里多条曲线用不同颜色区分时，自动找出每条曲线的颜色和
%   一个可靠的代表点（种子点），交给后续追踪。这样用户不用手动逐条点。
%
%   用法: cand = colorCurves(I, ax)
%     I  : 图像；ax : 轴框结构体
%     opts.maxCurves  最多返回多少条（默认 12）
%     opts.minPix     一个颜色至少多少像素才算曲线（默认 60）
%
%   返回 cand 结构体数组：
%     .color  1x3 代表色（RGB，0-255）
%     .size   该颜色在轴框内的像素数
%     .seed   [x y] 建议的种子点（该颜色最"孤立"的像素，避开交叉处）
%     .yMean  该颜色的平均行号（用于排序/命名）
%
%   做法：把颜色量化成粗格子做直方图，取像素多的格子做非极大值抑制，
%   再对每个颜色统计像素分布、挑一个远离其他颜色的点作为种子。
%   只用 MATLAB 基础函数（accumarray / 量化），不需要工具箱。

    if nargin < 3, opts = struct(); end
    if ~isfield(opts,'maxCurves'), opts.maxCurves = 12; end
    if ~isfield(opts,'minPix'),    opts.minPix = 60;    end
    if ~isfield(opts,'q'),         opts.q = 16;         end   % 量化级数
    if ~isfield(opts,'splitShades'), opts.splitShades = true; end
    if ~isfield(opts,'shadeThresh'), opts.shadeThresh = 0.06; end % 明度分档阈值
    % 颜色非极大值抑制的容差：默认 30（原为 60）。
    % 实测 Fig.3A 的 9 档绿相邻核心色只差 59，容差 60 会把整族并成两三条；
    % 而抗锯齿产生的"同一条曲线的多个色阶"相距通常 < 30，30 仍能合并它们。
    if ~isfield(opts,'nmsTol'), opts.nmsTol = 30; end
    % 同一条曲线的抗锯齿色阶，深浅差上限（0-255 尺度）。超过它就认为是
    % 另一条"同色相不同深浅"的曲线，不合并。
    if ~isfield(opts,'shadeKeep'), opts.shadeKeep = 25; end

    cand = struct('color', {}, 'size', {}, 'seed', {}, 'yMean', {});

    D = double(I);
    [H, W, ~] = size(D);
    if size(D,3) < 3
        return;                     % 灰度图没有颜色可分离
    end

    % 只统计轴框内部
    r0 = max(1, round(ax.rowTop)+1);  r1 = min(H, round(ax.rowBottom)-1);
    c0 = max(1, round(ax.colLeft)+1); c1 = min(W, round(ax.colRight)-1);
    if r1 <= r0 || c1 <= c0, return; end

    sub = D(r0:r1, c0:c1, :);
    hs = size(sub,1); ws = size(sub,2);

    R = sub(:,:,1); G = sub(:,:,2); B = sub(:,:,3);
    mx = max(sub, [], 3); mn = min(sub, [], 3);
    sat = mx - mn;                          % 简易饱和度
    lum = 0.299*R + 0.587*G + 0.114*B;

    % 背景（白/浅灰）与纯黑文字都排除：
    %   背景 -> 饱和度低且很亮
    %   文字/网格 -> 饱和度低且很暗
    % 剩下的才是"有颜色的曲线"，加上"无彩色但明显的彩色外框"这类情况。
    isBG = (sat < 40) & (lum > 170);
    isInk = (sat < 40) & (lum <= 170);      % 黑/灰线（文字、边框、黑曲线）

    q = opts.q;
    step = 256/q;
    qr = min(q-1, floor(R/step)); qg = min(q-1, floor(G/step)); qb = min(q-1, floor(B/step));
    key = qr*q*q + qg*q + qb;

    % ---- 彩色曲线：按量化色统计 ----
    maskC = ~isBG & ~isInk;
    keys = key(maskC);
    if ~isempty(keys)
        [uk, ~, ic] = unique(keys);
        cnt = accumarray(ic, 1);
        [cnt, o] = sort(cnt, 'descend');
        uk = uk(o);
        for k = 1:min(numel(uk), 40)
            if cnt(k) < opts.minPix, break; end
            m = (key == uk(k)) & maskC;
            col = [mean(R(m)), mean(G(m)), mean(B(m))];
            % 非极大值抑制：和已选颜色太近就跳过。
            % 容差取"同色系深浅的最小间距"的一半 —— 不能再用固定的 60：
            % 实测 Fig.3A 的 9 档绿，相邻核心色只差 59，固定 60 会把它们全并掉。
            if tooClose(col, cand, opts.nmsTol), continue; end
            [seed, yMean] = pickSeed(m, r0, c0);
            if isempty(seed), continue; end
            cand(end+1) = struct('color', col, 'size', nnz(m), ...
                                 'seed', seed, 'yMean', yMean); %#ok<AGROW>
            if numel(cand) >= opts.maxCurves, break; end
        end
    end

    % ---- 黑/灰曲线：整体当一个候选（多条黑线只能靠手动点选区分）----
    if nnz(maskC) < opts.minPix && nnz(isInk) >= opts.minPix
        m = isInk;
        [seed, yMean] = pickSeed(m, r0, c0);
        if ~isempty(seed)
            cand(end+1) = struct('color', [0 0 0], 'size', nnz(m), ...
                                 'seed', seed, 'yMean', yMean);
        end
    end

    % ---- 同色系多曲线：靠"端部列"数出有几条 ----
    % 论文里同色不同深浅的多条曲线（如 7 档绿）在明度上往往是连续分布，
    % 直方图没有可分峰，按明度分层行不通。
    % 但它们通常在左端或右端是彼此分开的 —— 直接数端部列里有几簇同色像素，
    % 每簇就是一个种子点。这是人看图的方式，稳定得多。
    if opts.splitShades
        extra = seedsFromEdges(sub, ax, R, G, B, lum, cand, opts);
        if ~isempty(extra)
            cand = [cand, extra];
        end
    end

    % 按平均位置从上到下排序（与图例顺序通常一致）
    if ~isempty(cand)
        [~, o] = sort([cand.yMean]);
        cand = cand(o);
    end

    % ---- 合并"同一条曲线的抗锯齿色阶"，但保留同色系的深浅差异 ----
    % 这是本函数最要紧的一步，之前的做法（只按色相聚类）有致命缺陷：
    % 论文图里"同一色相、不同深浅"的多条曲线（如 Fig.3A 的 9 档绿）
    % 色相完全一样，只按色相聚类就会把整个色系并成一条 —— 表现为
    % "自动分离不准确 / 条数少了好几条"。
    % 新判据：色相接近 且 深浅（1-明度）接近 才算同一条曲线。
    % 抗锯齿造成的多个色阶深浅差很小（< ~25），会被合并；
    % 不同条件曲线的深浅差通常 ≥ 50，会被保留。
    cand = mergeShadeFamily(cand, opts.shadeKeep);
end

%
function col = colorShade(col)
%COLORSHADE  颜色的"深浅"标量：0=最亮，1=最暗（白 0、纯绿 0.5、黑 1）
    col = double(col);
    mx = max(col);
    if mx <= 0, c = 0; else, c = (mx - min(col)) / mx; end
    dk = 1 - mean(col)/255;
    col = (1 - c) * dk + c * dk * 0.5;
end

%
function cand = mergeShadeFamily(cand, shadeKeep)
%MERGESHADEFAMILY  同一色相+同一深浅 -> 合并；同色相不同深浅 -> 各自保留
    if nargin < 2 || isempty(shadeKeep), shadeKeep = 25; end
    if numel(cand) < 2, return; end
    n = numel(cand);
    hue = zeros(1,n); sat = zeros(1,n); shade = zeros(1,n);
    for k = 1:n
        [hue(k), sat(k)] = rgbHue(cand(k).color);
        shade(k) = colorShade(cand(k).color);
    end

    parent = 1:n;
    for a = 1:n
        for b = a+1:n
            ra = findRoot(parent, a); rb = findRoot(parent, b);
            if ra == rb, continue; end
            if sat(a) < 0.10 || sat(b) < 0.10
                % 灰/黑：按 RGB 距离合并（黑曲线的抗锯齿灰阶）
                if sat(a) < 0.10 && sat(b) < 0.10 && ...
                   norm(double(cand(a).color) - double(cand(b).color)) < 90
                    parent(rb) = ra;
                end
                continue;
            end
            dh = abs(hue(a) - hue(b)); dh = min(dh, 1 - dh);
            if dh < 0.03 && abs(shade(a) - shade(b)) * 255 <= shadeKeep
                parent(rb) = ra;
            end
        end
    end

    out = struct('color', {}, 'size', {}, 'seed', {}, 'yMean', {});
    rl = zeros(1,n);
    for k = 1:n, rl(k) = findRoot(parent, k); end   % 每个候选取一次根，避免重复遍历
    u = unique(rl);
    for q = 1:numel(u)
        idx = find(rl == u(q));
        sz = 0; wsum = [0 0 0]; ysum = 0;
        for k = idx
            c = double(cand(k).color);
            wsum = wsum + c * cand(k).size;
            sz = sz + cand(k).size;
            ysum = ysum + cand(k).yMean * cand(k).size;
        end
        col = wsum / max(1, sz);
        out(end+1) = struct('color', col, 'size', sz, ...
            'seed', cand(idx(1)).seed, 'yMean', ysum / max(1, sz)); %#ok<AGROW>
    end
    [~, o] = sort([out.yMean]);
    cand = out(o);
end

function r = findRoot(parent, x)
    r = x;
    while parent(r) ~= r, r = parent(r); end
end

%
function cand = splitByShade(D, sub, ax, maskC, R, G, B, lum, cand, opts)
%SPLITBYSHADE  把"同色相但深浅不同"的多条曲线拆开。
%
%   动机：论文里常用同一色相的不同深浅表示不同条件（例如 7 档绿色）。
%   只按色相聚类会把它们并成一条，导致漏掉曲线。
%   这里对每个色相组，按明度做一维聚类（间隔超过阈值的断开），
%   每组单独成一个候选。
%
%   注意：只在"该色相像素明显多于一条曲线的量"时才拆，避免把一条线
%   抗锯齿产生的深浅边误拆成多条。

    r0 = max(1, round(ax.rowTop)+1);  r1 = min(size(D,1), round(ax.rowBottom)-1);
    c0 = max(1, round(ax.colLeft)+1); c1 = min(size(D,2), round(ax.colRight)-1);

    out = struct('color', {}, 'size', {}, 'seed', {}, 'yMean', {});

    % 按色相把已有候选分组
    hues = zeros(1, numel(cand));
    for k = 1:numel(cand)
        hues(k) = rgbHueLocal(cand(k).color);
    end
    groups = {};
    used = false(1, numel(cand));
    for k = 1:numel(cand)
        if used(k), continue; end
        g = k; used(k) = true;
        for m = k+1:numel(cand)
            if used(m), continue; end
            dh = abs(hues(k) - hues(m)); dh = min(dh, 1-dh);
            if dh < 0.03, g(end+1) = m; used(m) = true; end %#ok<AGROW>
        end
        groups{end+1} = g; %#ok<AGROW>
    end

    for gi = 1:numel(groups)
        idx = groups{gi};
        % 该组所有像素（含抗锯齿边）
        mAll = false(size(maskC));
        for k = idx
            col = cand(k).color;
            m = maskC & (R-col(1)).^2 + (G-col(2)).^2 + (B-col(3)).^2 <= 60^2;
            mAll = mAll | m;
        end
        npx = nnz(mAll);
        if npx < 50, continue; end

        % 明度直方图：找明显的峰/谷
        L = lum(mAll);
        nb = 40;
        edges = linspace(min(L), max(L)+1e-6, nb+1);
        h = histcounts(L, edges);
        centers = (edges(1:end-1) + edges(2:end))/2;

        % 只在直方图有明显多峰时才拆
        span = max(L) - min(L);
        if span < 25, continue; end            % 明度几乎一样 -> 就一条线
        minPk = max(8, 0.03*npx);
        peaks = find(h >= minPk);
        % 合并相邻桶成一个峰
        pkCenters = [];
        s = 1;
        for k = 2:numel(peaks)+1
            if k > numel(peaks) || peaks(k) - peaks(k-1) > 1
                seg = peaks(s:k-1);
                [~, bi] = max(h(seg));
                pkCenters(end+1) = centers(seg(bi)); %#ok<AGROW>
                s = k;
            end
        end
        % 去掉间距太近的峰（抗锯齿造成）
        keepPk = true(1, numel(pkCenters));
        for a = 1:numel(pkCenters)
            for b = a+1:numel(pkCenters)
                if abs(pkCenters(a)-pkCenters(b)) < opts.shadeThresh*255
                    keepPk(b) = false;
                end
            end
        end
        pkCenters = pkCenters(keepPk);
        if numel(pkCenters) <= 1
            % 只有一档 -> 保持原候选不变
            for k = idx, out(end+1) = cand(k); end %#ok<AGROW>
            continue;
        end

        % 按最近的峰把像素分给各档
        for p = 1:numel(pkCenters)
            mp = mAll & abs(lum - pkCenters(p)) <= opts.shadeThresh*255;
            if nnz(mp) < opts.minPix, continue; end
            col = [mean(R(mp)), mean(G(mp)), mean(B(mp))];
            [seed, yMean] = pickSeed(mp, r0, c0);
            if isempty(seed), continue; end
            out(end+1) = struct('color', col, 'size', nnz(mp), ...
                                'seed', seed, 'yMean', yMean); %#ok<AGROW>
        end
    end

    if ~isempty(out), cand = out; end
end

function h = rgbHueLocal(col)
    c = double(col)/255;
    mx = max(c); mn = min(c); d = mx - mn;
    if d == 0, h = 0; return; end
    switch mx
        case c(1), h = mod((c(2)-c(3))/d, 6);
        case c(2), h = (c(3)-c(1))/d + 2;
        otherwise, h = (c(1)-c(2))/d + 4;
    end
    h = h/6; if h < 0, h = h + 1; end
end

%
function extra = seedsFromEdges(sub, ax, R, G, B, lum, cand, opts)
%SEEDSFROMEDGES  扫描多个横向位置，数出"同色系"曲线各有几条并给出种子点。
%
%   为什么不能只看端部：论文图里同色系曲线常在两端汇聚（都从 0 出发、
%   或都收敛到平台），端部只看得到一条；而中段往往分得很开。
%   实测某面板：2% 处 0 簇、25% 处 5 簇、50% 处 6 簇、97% 处 0 簇。
%   所以做法是扫多个位置，把各位置数到的簇汇总后去重。
%
%   这条路径专门解决"同色相、只靠颜色分不开"的多曲线问题。

    extra = struct('color', {}, 'size', {}, 'seed', {}, 'yMean', {});
    D = double(sub);
    [hs, ws, ~] = size(D);
    r0 = max(1, round(ax.rowTop)+2);  r1 = min(hs, round(ax.rowBottom)-2);
    c0 = max(1, round(ax.colLeft)+2); c1 = min(ws, round(ax.colRight)-2);
    if r1 <= r0 || c1 <= c0, return; end

    mxv = max(D,[],3); mnv = min(D,[],3);
    satAll = mxv - mnv;
    lumAll = 0.299*D(:,:,1) + 0.587*D(:,:,2) + 0.114*D(:,:,3);
    % 彩色像素：有饱和度，且不是极亮背景
    isColor = (satAll >= 45) & (lumAll <= 240);

    L = r1 - r0 + 1;
    fracs = [0.10 0.20 0.30 0.40 0.50 0.60 0.70 0.80 0.90];
    halfw = max(2, round(0.01*(c1-c0)));     % 每个位置取左右各 1% 宽的竖条

    raw = struct('y', {}, 'color', {}, 'yMean', {});
    for fi = 1:numel(fracs)
        cc = round(c0 + fracs(fi)*(c1-c0));
        cols = max(c0, cc-halfw) : min(c1, cc+halfw);
        band = isColor(r0:r1, cols);
        rowCnt = sum(band, 2);
        on = rowCnt > 0;
        d = diff([false; on(:); false]);
        ss = find(d == 1); ee = find(d == -1) - 1;
        for c = 1:numel(ss)
            rows = ss(c):ee(c);
            if numel(rows) < 1, continue; end
            if sum(rowCnt(rows)) < 4, continue; end
            % 该簇的像素索引
            sel = false(hs, ws);
            sel(r0+rows-1, cols) = band(rows, :);
            npx = nnz(sel);
            if npx < 6, continue; end
            % 颜色取"最饱和的那部分"，避免抗锯齿把颜色拉灰
            idx = find(sel);
            cols3 = reshape(D, [], 3);
            pk = cols3(idx, :);
            s2 = max(pk,[],2) - min(pk,[],2);
            [~, o] = sort(s2, 'descend');
            take = o(1:max(1, round(0.4*numel(o))));
            col = mean(pk(take,:), 1);
            if max(col)-min(col) < 40, continue; end   % 无彩色，跳过
            raw(end+1) = struct('y', mean(r0+rows-1), 'color', col, ...
                                'yMean', mean(r0+rows-1)); %#ok<AGROW>
        end
    end
    if isempty(raw), return; end

    % ---- 去重：颜色接近且纵向位置接近的视为同一条曲线 ----
    keep = true(1, numel(raw));
    for a = 1:numel(raw)
        if ~keep(a), continue; end
        for b = a+1:numel(raw)
            if ~keep(b), continue; end
            dc = norm(double(raw(a).color) - double(raw(b).color));
            dy = abs(raw(a).y - raw(b).y);
            if dc < 45 && dy < 12
                keep(b) = false;          % 合并到 a
            end
        end
    end
    raw = raw(keep);

    % 只保留像素量足够、且没被已有候选覆盖的
    for k = 1:numel(raw)
        if raw(k).y < r0 || raw(k).y > r1, continue; end
        col = raw(k).color;
        if tooCloseLocal(col, cand, 55), continue; end
        if tooCloseLocal(col, extra, 45), continue; end
        extra(end+1) = struct('color', col, 'size', 50, ...
            'seed', [round((c0+c1)/2), round(raw(k).y)], ...
            'yMean', raw(k).y); %#ok<AGROW>
    end
end

function tf = tooCloseLocal(col, list, tol)
    tf = false;
    for k = 1:numel(list)
        if norm(double(col) - double(list(k).color)) < tol, tf = true; return; end
    end
end

%
function tf = covered(col, mask, R, G, B, cand) %#ok<INUSD>
%COVERED  预留：该簇是否已被现有候选覆盖
    tf = false;
end

%
function cand = mergeColors(cand, tolHue)
%MERGECOLORS  按色相把颜色相近的候选合并成一簇。
%
%   为什么不按 RGB 欧氏距离：抗锯齿会在一条曲线周围产生深浅不一的色阶
%   （深蓝 0,0,128 / 中蓝 55,55,205 / 浅蓝 183,183,237），它们在 RGB 空间
%   距离很大，但色相相同 —— 应该算同一条曲线。反之蓝和红色相相差很大，
%   即使亮度接近也不能合并。所以用色相聚类，亮度不参与。
    if numel(cand) < 2, return; end
    n = numel(cand);
    hue = zeros(1,n); satv = zeros(1,n);
    for k = 1:n
        [hue(k), satv(k)] = rgbHue(cand(k).color);
    end

    label = 1:n;
    for a = 1:n
        for b = a+1:n
            if satv(a) < 0.10 || satv(b) < 0.10
                % 有一方是灰/黑：只有两方都很暗（同为黑线）才合并
                if satv(a) < 0.10 && satv(b) < 0.10
                    if norm(double(cand(a).color) - double(cand(b).color)) < 90
                        label(label == label(b)) = label(a);
                    end
                end
                continue;
            end
            dh = abs(hue(a) - hue(b));
            dh = min(dh, 1 - dh);              % 色相是环形的
            if dh < tolHue
                label(label == label(b)) = label(a);
            end
        end
    end

    out = struct('color', {}, 'size', {}, 'seed', {}, 'yMean', {});
    for u = unique(label)
        idx = find(label == u);
        [~, bi] = max([cand(idx).size]);
        rep = cand(idx(bi));
        rep.size = sum([cand(idx).size]);
        out(end+1) = rep; %#ok<AGROW>
    end
    [~, o] = sort([out.yMean]);
    cand = out(o);
end

%
function [h, s] = rgbHue(col)
%RGBHUE  计算色相（0~1）与饱和度（0~1，定义为 (mx-mn)/mx）
    c = double(col) / 255;
    mx = max(c); mn = min(c);
    d = mx - mn;
    if mx <= 0, s = 0; else, s = d / mx; end
    if d == 0, h = 0; return; end
    switch mx
        case c(1), h = mod((c(2)-c(3))/d, 6);
        case c(2), h = (c(3)-c(1))/d + 2;
        otherwise, h = (c(1)-c(2))/d + 4;
    end
    h = h / 6;
    if h < 0, h = h + 1; end
end

%
function tf = tooClose(col, cand, tol)
    tf = false;
    for k = 1:numel(cand)
        if norm(col - cand(k).color) < tol, tf = true; return; end
    end
end

%
function [seed, yMean] = pickSeed(m, r0, c0)
%PICKSEED  在该颜色的像素里挑一个"离其他颜色最远"的点当种子。
%   直觉：交叉/重叠处颜色会混，选孤立处的点追踪最不容易跑偏。
    seed = []; yMean = NaN;
    [yy, xx] = find(m);
    if isempty(yy), return; end
    yMean = mean(yy) + r0 - 1;

    % 每列取一个代表点（该列该颜色的中位行）
    [ux, ~, ic] = unique(xx);
    ymed = accumarray(ic, yy, [], @median);
    nPer = accumarray(ic, 1);
    % 只保留该列像素数接近"典型线宽"的列（避开交叉处的一大坨、标记符号）
    typical = median(nPer);
    ok = nPer <= max(4, 2.2*typical);
    if ~any(ok)
        ok = true(size(ux));
    end
    ux = ux(ok); ymed = ymed(ok);

    % 在满足条件的列里，挑"最长连续干净段"，再取该段中间区域的一个点。
    % 注意要避开图例：图例常带同色样本，落在那里会从图例开始追踪。
    % 这里用 yMean 判断上下半区，把种子推到远离图例的一侧。
    bestLen = 0; bestS = 1; bestE = numel(ux);
    s = 1;
    for k = 2:numel(ux)+1
        if k > numel(ux) || ux(k) - ux(k-1) > 3
            len = k - s;
            if len > bestLen
                bestLen = len; bestS = s; bestE = k-1;
            end
            s = k;
        end
    end
    if bestE < bestS, bestS = 1; bestE = numel(ux); end

    % 若该颜色的像素平均位置偏上，就在窗口里偏上取样；否则偏下
    [~, rel] = min(abs(ymed(bestS:bestE) - yMean));
    win = bestS:bestE;
    pick = win(min(numel(win), max(1, rel)));
    seed = [ux(pick) + c0 - 1, ymed(pick) + r0 - 1];
end
