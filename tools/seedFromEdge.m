function cand = seedFromEdge(I, ax, opts)
%SEEDFROMEDGE  在轴框的某一端取种子 —— 专治"一端汇聚的曲线族"
%
%   cand = seedFromEdge(I, ax, opts)
%
%   ==================== 为什么需要这一路 ====================
%   实测 Fig.3D：9 档绿色的 V 形曲线族，全部在 x≈0 汇聚成一条竖线。
%   "多位置扫描"给出的种子几乎都落在汇聚处 —— 那里 9 条曲线重合，
%   DP 无从区分，只能提到一条。而**右端它们分得最开**（间距 20~40 px），
%   在那里每个颜色-位置组合都唯一对应一条曲线。
%   所以：在轴框右端附近的窄列带里，把所有"彩色竖条"逐条取出来当种子。
%
%   ==================== 做法 ====================
%   1) 取轴框右侧 sideFrac（默认 8%）宽的列带；
%   2) 带内找彩色像素，按行连通分簇，簇内再按颜色细分（与列扫描同一套）；
%   3) 每个簇给一个候选：颜色 = 簇内中位色，种子 = 该簇在**带内最靠右**的列；
%   4) 过滤：像素数太少、纵向太薄（< 1.5 px 的碎点）的丢掉。
%
%   opts.side      'right'（默认）或 'left'
%   opts.sideFrac  列带宽度占轴框宽的比例（默认 0.08）
%   opts.minPix    一个簇至少多少像素（默认 18）
%
%   返回 cand(k).color / .seed / .size / .yMean / .spanX(NaN) / .from

    if nargin < 3, opts = struct(); end
    side     = getf(opts,'side','right');
    sideFrac = getf(opts,'sideFrac',0.08);
    minPix   = getf(opts,'minPix',18);

    cand = struct('color', {}, 'size', {}, 'seed', {}, 'yMean', {}, ...
                  'spanX', {}, 'from', {});

    D = double(I);
    [H, W, ~] = size(D);
    if size(D,3) < 3, return; end

    r0 = max(1, round(ax.rowTop)+3);  r1 = min(H, round(ax.rowBottom)-3);
    c0 = max(1, round(ax.colLeft)+3); c1 = min(W, round(ax.colRight)-3);
    if r1 <= r0 || c1 <= c0, return; end

    % ---- 先找"最靠端的、确实含彩色像素的列" ----
    %   不能直接取最右 sideFrac 宽的带：实测 Fig.3D 的曲线只画到轴框 66% 处，
    %   右侧 1/3 是空白，取最右带会得到 0 个种子。
    allc = D(r0:r1, c0:c1, :);
    mxA = max(allc,[],3); mnA = min(allc,[],3);
    lumA = 0.299*allc(:,:,1) + 0.587*allc(:,:,2) + 0.114*allc(:,:,3);
    isColA = ((mxA - mnA) >= 45) & (lumA <= 242);
    perCol = sum(isColA, 1);
    valid = find(perCol >= 3);
    if isempty(valid), return; end

    if strcmpi(side,'left')
        cEdge = valid(1);
        ca = cEdge;
        cb = min(c1, cEdge + max(4, round(sideFrac*(c1-c0))));
    else
        cEdge = valid(end);
        cb = cEdge;
        ca = max(c0, cEdge - max(4, round(sideFrac*(c1-c0))));
    end
    bw = cb - ca + 1;

    sub = D(r0:r1, ca:cb, :);
    R = sub(:,:,1); G = sub(:,:,2); B = sub(:,:,3);
    mx = max(sub,[],3); mn = min(sub,[],3);
    lum = 0.299*R + 0.587*G + 0.114*B;
    isColor = ((mx - mn) >= 45) & (lum <= 242);
    [rr, cc] = find(isColor);
    if isempty(rr), return; end
    pix = zeros(numel(rr), 3);
    for ch = 1:3
        chD = sub(:,:,ch);
        pix(:,ch) = chD(isColor);
    end

    % 靠近轴脊的彩色像素要排除：那里是"黑色轴脊 + 彩色曲线"的过渡像素，
    % 颜色是混出来的假色，会被当成一条独立的曲线（实测 Fig.3A 出现过
    % [34 187 34] 这种"平均色"候选，指向的就是轴脊过渡带）。
    bad = (cc <= 3) | (cc >= bw - 2) | (rr <= 3) | (rr >= (r1-r0+1) - 2);
    rr(bad) = []; cc(bad) = []; pix(bad,:) = [];
    if isempty(rr), return; end

    % 按行连通分簇
    present = false(r1-r0+1, 1);
    present(rr) = true;
    d = diff([false; present; false]);
    ss = find(d == 1); ee = find(d == -1) - 1;
    for k = 1:numel(ss)
        m = rr >= ss(k) & rr <= ee(k);
        if nnz(m) < minPix, continue; end
        rowsK = rr(m); colsK = cc(m); pk = pix(m,:);
        % 簇内按颜色细分（复用列扫描里同一套逻辑）
        groups = splitByColor(pk);
        for g = 1:numel(groups)
            gi = groups{g};
            if numel(gi) < minPix, continue; end
            col = median(pk(gi,:), 1);
            if max(col) - min(col) < 30, continue; end
            % 种子取"带内最靠端"的那一列（最远离汇聚端）
            if strcmpi(side,'left')
                [xc, xi] = min(colsK(gi));
            else
                [xc, xi] = max(colsK(gi));
            end
            rrI = rowsK(gi);
            rrSel = rrI(xi);
            % 该列附近至少要有 2 个像素，避免取到抗锯齿孤点
            band = rrI(abs(colsK(gi) - xc) <= 1);
            if numel(band) < 2, continue; end
            cand(end+1) = struct('color', col, 'size', numel(gi), ...
                'seed', [ca + xc - 1, r0 + rrSel - 1], ...
                'yMean', r0 + mean(rrI) - 1, 'spanX', NaN, ...
                'from', 'edge'); %#ok<AGROW>
        end
    end
    if false, bw = bw; end %#ok<NASGU>

    % 去掉颜色+位置都几乎一样的重复候选
    if numel(cand) > 1
        keep = true(1, numel(cand));
        for a = 1:numel(cand)
            if ~keep(a), continue; end
            for b = a+1:numel(cand)
                if ~keep(b), continue; end
                dc = max(abs(double(cand(a).color) - double(cand(b).color)));
                dy = abs(cand(a).seed(2) - cand(b).seed(2));
                if dc <= 30 && dy <= 8, keep(b) = false; end
            end
        end
        cand = cand(keep);
    end
end

% =====================================================================
function groups = splitByColor(pix)
%SPLITBYCOLOR  把一组像素按颜色分成 1~2 个子集（分不开就保持一组）
    n = size(pix, 1);
    groups = {1:n};
    if n < 30, return; end
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
    if nnz(idx==1) < 0.15*n || nnz(idx==2) < 0.15*n, return; end
    groups = {find(idx==1), find(idx==2)};
end

% =====================================================================
function v = getf(s, f, d)
    if isstruct(s) && isfield(s, f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end
