function cand = colorLevelSeeds(I, ax, opts)
%COLORLEVELSEEDS  按"颜色层"逐层给种子 —— 专治同色系多条曲线
%
%   cand = colorLevelSeeds(I, ax, opts)
%
%   ==================== 思路 ====================
%   同色系的多条曲线（Fig.3A 的 9 档绿、Fig.3D 的 9 档绿、Fig.3F 的深浅两条）
%   有一个共同特点：**每条曲线都有一批"实芯"像素，其颜色几乎恒定**；
%   颜色之所以看起来分不开，是因为抗锯齿把边界糊成了连续分布。
%   所以只要能把这些"实芯色层"找出来，每条曲线就有一个干净的代表色。
%
%   做法：
%     ① 只在轴框内取"彩色像素"；
%     ② 用贪心聚类把这些像素的颜色聚成若干层（层间色距 > tol）；
%     ③ 每层里挑一个**实芯像素**当种子：
%        要求它上下左右邻域内也有同层像素（说明不是抗锯齿孤点）；
%     ④ 按该层像素数排序，层太小（< minPix）的丢掉。
%
%   本函数只负责"给出代表色与种子"；取点仍交给 traceByDP。
%   因为它只用颜色（不跨列归组），所以不会像"轨迹关联"那样串线。
%
%   opts:
%     .tol        层间颜色容差（默认 42）
%     .minPix     一层至少多少像素（默认 60）
%     .maxCurves  上限（默认 16）
%     .fracs      取种子的候选列位置（相对轴框宽，默认 0.08:0.06:0.92）
%                 种子在**多个列位置里挑"该层最孤立"的那个**：
%                 孤立 = 该列上下别的层离它远，这样 DP 不容易被邻层拉走。

    if nargin < 3, opts = struct(); end
    tol       = getf(opts,'tol',42);
    minPix    = getf(opts,'minPix',60);
    maxCurves = getf(opts,'maxCurves',16);
    fracs     = getf(opts,'fracs',0.08:0.06:0.92);

    cand = struct('color', {}, 'size', {}, 'seed', {}, 'yMean', {}, ...
                  'spanX', {}, 'from', {});

    D = double(I);
    [H, W, ~] = size(D);
    if size(D,3) < 3, return; end
    r0 = max(1, round(ax.rowTop)+3);  r1 = min(H, round(ax.rowBottom)-3);
    c0 = max(1, round(ax.colLeft)+3); c1 = min(W, round(ax.colRight)-3);
    if r1 <= r0 || c1 <= c0, return; end

    sub = D(r0:r1, c0:c1, :);
    mx = max(sub,[],3); mn = min(sub,[],3);
    lum = 0.299*sub(:,:,1) + 0.587*sub(:,:,2) + 0.114*sub(:,:,3);
    isColor = ((mx - mn) >= 45) & (lum <= 242);

    [rr, cc] = find(isColor);
    if numel(rr) < minPix, return; end
    pix = reshape(sub, [], 3);
    idxLin = sub2ind(size(isColor), rr, cc);
    % 用线性索引一次性取色（比逐通道快）
    pix = pix(idxLin, :);

    % ---------- ② 贪心颜色分层 ----------
    %   按像素数从多到少遍历，每层一个中心；离所有中心都超过 tol 才开新层。
    %   为了快，先按"颜色量化"预聚一次（每通道 >>2 再数），再对代表色聚类。
    key = (bitshift(uint32(pix(:,1)), 16) + bitshift(uint32(pix(:,2)), 8) + uint32(pix(:,3)));
    [uk, ~, ic] = unique(key);
    cnt = accumarray(ic, 1);
    [cnt, o] = sort(cnt, 'descend');
    uk = uk(o);
    centers = zeros(0,3);
    centerCount = [];
    centerPixIdx = {};        % 每层对应的像素下标（先收集，最后再精确化）
    for k = 1:numel(uk)
        if cnt(k) < 4, continue; end
        v = uk(k);
        col = [double(bitshift(v, -16)), double(bitand(bitshift(v, -8), 255)), double(bitand(v, 255))];
        if isempty(centers)
            dd = inf;
        else
            dd = min(max(abs(centers - col), [], 2));
        end
        if isempty(centers) || dd > tol
            centers(end+1,:) = col;             %#ok<AGROW>
            centerCount(end+1) = cnt(k);        %#ok<AGROW>
        else
            [~, mi] = min(max(abs(centers - col), [], 2));
            centerCount(mi) = centerCount(mi) + cnt(k);
        end
    end
    if isempty(centers), return; end

    % 分配每个像素到最近中心（得到每层像素，顺便精确重算中位色）
    assign = zeros(size(pix,1),1);
    best = inf(size(pix,1),1);
    for k = 1:size(centers,1)
        dd = max(abs(pix - centers(k,:)), [], 2);
        upd = dd < best;
        best(upd) = dd(upd);
        assign(upd) = k;
    end

    % ---------- ③ 每层给一个种子 ----------
    mSub = false(size(isColor));
    mSub(idxLin) = true;
    dense = conv2(double(mSub), ones(3), 'same') >= 5;
    denseV = dense(idxLin);          % 每个彩色像素的"实芯"标记

    for k = 1:size(centers,1)
        sel = assign == k;
        n = nnz(sel);
        if n < minPix, continue; end
        col = median(pix(sel,:), 1);
        if max(col) - min(col) < 30, continue; end
        rowsK = rr(sel); colsK = cc(sel);      % 本层像素（下标是"本层内"的）
        selV  = find(sel);                      % 本层像素在全体彩色像素里的位置

        % 先在"实芯"像素里挑；没有就退回全部本层像素
        pickPool = denseV(selV);                % 与 rowsK 对齐
        localIdx = find(pickPool);
        if isempty(localIdx), localIdx = (1:numel(rowsK))'; end

        % 在候选里挑"最孤立"的那个：该列上下别的层的像素离它越远越好
        colOf = colsK(localIdx);
        sep = zeros(numel(localIdx),1);
        other = ~sel;
        rowsOther = rr(other); colsOther = cc(other);
        for j = 1:numel(localIdx)
            inCol = colsOther == colOf(j);
            if any(inCol)
                sep(j) = min(abs(rowsOther(inCol) - rowsK(localIdx(j))));
            else
                sep(j) = 1e3;
            end
        end
        % 只在若干采样列里挑（避免种子落在极窄的尖峰上）
        sampCols = round(1 + fracs*(c1-c0));
        okSamp = ismember(colOf + c0, sampCols);
        if any(okSamp)
            idxPick = find(okSamp);
            [~, bi] = max(sep(idxPick));
            pick = localIdx(idxPick(bi));
        else
            [~, bi] = max(sep);
            pick = localIdx(bi);
        end

        cand(end+1) = struct('color', col, 'size', n, ...
            'seed', [c0 + colsK(pick) - 1, r0 + rowsK(pick) - 1], ...
            'yMean', r0 + mean(rowsK) - 1, 'spanX', NaN, ...
            'from', 'level'); %#ok<AGROW>
    end

    % ---------- ④ 按像素数取前 N，按纵向位置排序 ----------
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
function v = getf(s, f, d)
    if isstruct(s) && isfield(s, f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end
