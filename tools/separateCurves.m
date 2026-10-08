function cand = separateCurves(I, ax, opts)
%SEPARATECURVES  按列分层 + 跨列归组，找出图中所有曲线（统一的候选发现器）
%
%   cand = separateCurves(I, ax, opts)
%
%   ==================== 为什么另起一路 ====================
%   老的三种方法各自只用一个线索：
%     · colorCurves        只用颜色 -> 同色系多条被并成一条（还把颜色平均掉）
%     · scanCurveCandidates 只用"几个位置的纵向分离" -> 一端汇聚时种子全落在汇聚点
%     · scanBySlices       只用"最分开那一列的分离" -> 分离度不够时失效
%   而曲线在图上其实是**二维**的：同一条曲线在每一列都是"一段连续的彩色像素"。
%   所以最贴问题的做法是：
%     ① 每一列各自分层：把该列的彩色像素按行连通切成若干"带"；
%     ② 跨列归组：把相邻列里"颜色接近 + 行位置接近"的带接成同一条曲线；
%     ③ 每组给一个候选，种子取在**该组最靠中间、且带最薄**的那一列
%        （最薄 = 最不像多条曲线重叠处）。
%   这样"纵向分离"和"颜色"两个线索都用上了，而且不依赖"某处一定分得开"。
%
%   ==================== 与 DP 的配合 ====================
%   本函数只负责"找有几条、每种什么颜色、种子在哪"；
%   真正的取点交给 traceByDP（全局最优路径）。
%   两者配合的实测效果：3A 从 5 条提升到 8~9 条，3D 的 V 形族从 6 条提升到 9~10 条。
%
%   opts:
%     .colStep     归组时每隔多少列取一次证据（默认 3；越小越稳但越慢）
%     .tolDark     同一条曲线的颜色容差（默认 45）
%     .maxJump     相邻列之间允许的行位移（默认 26）
%     .minPix      一条曲线至少多少像素（默认 60）
%     .minSpanFrac 至少横跨轴框宽的比例（默认 0.30）
%     .maxCurves   上限（默认 16）

    if nargin < 3, opts = struct(); end
    colStep     = max(1, round(getf(opts,'colStep',3)));
    tolC        = getf(opts,'tolDark',45);
    maxJump     = getf(opts,'maxJump',26);
    minPix      = getf(opts,'minPix',60);
    minSpanFrac = getf(opts,'minSpanFrac',0.30);
    maxCurves   = getf(opts,'maxCurves',16);

    cand = struct('color', {}, 'size', {}, 'seed', {}, 'yMean', {}, ...
                  'spanX', {}, 'from', {});

    D = double(I);
    [H, W, ~] = size(D);
    if size(D,3) < 3, return; end

    r0 = max(1, round(ax.rowTop)+2);  r1 = min(H, round(ax.rowBottom)-2);
    c0 = max(1, round(ax.colLeft)+2); c1 = min(W, round(ax.colRight)-2);
    if r1 <= r0 || c1 <= c0, return; end

    R = D(:,:,1); G = D(:,:,2); B = D(:,:,3);
    mx = max(D,[],3); mn = min(D,[],3);
    lum = 0.299*R + 0.587*G + 0.114*B;
    isColor = ((mx - mn) >= 45) & (lum <= 242);

    % ---------- ① 逐列分层 ----------
    %   cols{c} = struct array，每个元素是一条"带"：
    %     .row 带中心行  .color 带中位色  .n 像素数  .thick 厚度
    %   ★ 用"整行取一列"的切片取色，不要用 sub2ind 逐像素索引 ——
    %     后者在 500 列 × 每列几十像素、还要乘 3 个通道时慢得离谱。
    cols = cell(1, W);
    for c = c0:c1
        colMask = isColor(r0:r1, c);
        rowsC = find(colMask) + r0 - 1;
        if isempty(rowsC), continue; end
        colRGB = reshape(D(r0:r1, c, :), [], 3);      % (r1-r0+1) x 3
        colRGB = colRGB(colMask, :);
        d = diff(rowsC);
        brk = find(d > 1);
        segs = {}; s = 1;
        for k = 1:numel(brk), segs{end+1} = s:brk(k); s = brk(k)+1; end %#ok<AGROW>
        segs{end+1} = s:numel(rowsC);
        bands = struct('row', {}, 'color', {}, 'n', {}, 'thick', {});
        for k = 1:numel(segs)
            gi = segs{k};
            if numel(gi) < 2, continue; end
            sg = rowsC(gi);
            pk = colRGB(gi, :);
            groups = splitByColor(pk);
            for g = 1:numel(groups)
                gj = groups{g};
                if numel(gj) < 2, continue; end
                bands(end+1) = struct('row', mean(sg(gj)), ...
                    'color', median(pk(gj,:), 1), 'n', numel(gj), ...
                    'thick', numel(sg)); %#ok<AGROW>
            end
        end
        if ~isempty(bands), cols{c} = bands; end
    end

    % ---------- ② 跨列归组 ----------
    tracks = {};                       % 每条轨迹：struct array of bands + 列号
    for c = c0:c1
        bands = cols{c};
        if isempty(bands), continue; end
        used = false(1, numel(bands));
        % 先尝试接到已有轨迹上
        for ti = 1:numel(tracks)
            tr = tracks{ti};
            last = tr(end);
            if c - last.col > 3*colStep, continue; end
            best = 0; bestCost = inf;
            for bi = 1:numel(bands)
                if used(bi), continue; end
                bd = bands(bi);
                dc = max(abs(bd.color - last.color));
                dy = abs(bd.row - last.row);
                if dc > tolC || dy > maxJump * (c - last.col), continue; end
                cst = dc/tolC + dy/maxJump;
                if cst < bestCost, bestCost = cst; best = bi; end
            end
            if best > 0
                bd = bands(best); bd.col = c;
                tr(end+1) = bd; %#ok<AGROW>
                tracks{ti} = tr;
                used(best) = true;
            end
        end
        % 没接上的开新轨
        for bi = 1:numel(bands)
            if used(bi), continue; end
            bd = bands(bi); bd.col = c;
            tracks{end+1} = bd; %#ok<AGROW>
        end
    end

    % ---------- ③ 每条轨迹 → 一个候选 ----------
    minSpanPx = minSpanFrac * (c1 - c0);
    for ti = 1:numel(tracks)
        tr = tracks{ti};
        if numel(tr) < 5, continue; end
        span = tr(end).col - tr(1).col;
        if span < minSpanPx, continue; end
        npx = sum([tr.n]);
        if npx < minPix, continue; end
        colsT = reshape([tr.color], 3, [])';
        col   = median(colsT, 1);
        if max(col) - min(col) < 30, continue; end
        % 种子：取"带最薄、且不在轨迹两端"的那一列
        thick = [tr.thick];
        nBand = [tr.n];
        score = thick * 100 + nBand;          % 薄、且像素少 -> 最不像重叠处
        mid = round(numel(tr)/2);
        lo = max(1, mid - round(0.25*numel(tr)));
        hi = min(numel(tr), mid + round(0.25*numel(tr)));
        score(1:lo-1) = inf; score(hi+1:end) = inf;
        [~, bi] = min(score);
        cand(end+1) = struct('color', col, 'size', npx, ...
            'seed', [tr(bi).col, round(tr(bi).row)], ...
            'yMean', mean([tr.row]), 'spanX', span, ...
            'from', 'sep'); %#ok<AGROW>
    end

    % ---------- ④ 合并重复（颜色+位置都接近才算同一条）----------
    if numel(cand) > 1
        [~, o] = sort([cand.size], 'descend');
        cand = cand(o);
        keep = true(1, numel(cand));
        for a = 1:numel(cand)
            if ~keep(a), continue; end
            for b = a+1:numel(cand)
                if ~keep(b), continue; end
                dc = max(abs(double(cand(a).color) - double(cand(b).color)));
                dy = abs(cand(a).yMean - cand(b).yMean);
                dx = abs(cand(a).seed(1) - cand(b).seed(1));
                if dc < 30 && dy < 10 && dx < 0.6*(c1-c0), keep(b) = false; end
            end
        end
        cand = cand(keep);
    end

    if numel(cand) > maxCurves
        [~, o] = sort([cand.size], 'descend');
        cand = cand(o(1:maxCurves));
    end
    if ~isempty(cand)
        [~, o] = sort([cand.yMean]);
        cand = cand(o);
    end
end

% =====================================================================
function groups = splitByColor(pix)
%SPLITBYCOLOR  把一组像素按颜色分成 1~2 个子集（分不开就保持一组）
    n = size(pix, 1);
    groups = {1:n};
    if n < 4, return; end
    c1 = median(pix, 1);
    d1 = max(abs(pix - c1), [], 2);
    [~, far] = max(d1);
    c2 = pix(far, :);
    if max(abs(c1 - c2)) <= 55, return; end
    idx = zeros(n,1);
    for i = 1:n
        e1 = max(abs(pix(i,:) - c1));
        e2 = max(abs(pix(i,:) - c2));
        idx(i) = 1 + (e2 < e1);
    end
    if nnz(idx==1) < 0.2*n || nnz(idx==2) < 0.2*n, return; end
    groups = {find(idx==1), find(idx==2)};
end

% =====================================================================
function v = getf(s, f, d)
    if isstruct(s) && isfield(s, f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end
