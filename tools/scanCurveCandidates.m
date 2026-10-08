function cand = scanCurveCandidates(I, ax, opts)
%SCANCURVECANDIDATES  通过"多位置扫描 + 跨位置关联"找出图中所有曲线。
%
%   采用这个思路：只按颜色做直方图在两类常见图上都会失败 ——
%     * 同色系多条曲线（7 档绿、11 档绿）：色相相同，颜色分不开；
%     * 抗锯齿：一条线在颜色空间里被糊成连续的一片，峰分不出来。
%   但曲线在空间上通常是分得开的：在某个横向位置上，它们是几段
%   彼此分离的竖条。实测某面板：2% 处 0 簇、25% 处 5 簇、50% 处 6 簇、
%   97% 处 0 簇（两端汇聚）。
%
%   所以做法是：在多个横向位置各数一次"竖条簇"，再用
%   颜色 + 纵向连续性把不同位置的簇关联成同一条曲线。
%   关联成功的曲线会跨越多列，只有横跨足够宽、且在各位置都稳定出现的
%   组合才被接受 —— 这样能自动排除图例色块、误差棒、文字这些干扰。
%
%   用法: cand = scanCurveCandidates(I, ax)
%   返回 cand(k).color / .seed / .size / .yMean / .spanX
%
%   依赖：MATLAB 基础功能。

    if nargin < 3, opts = struct(); end
    if ~isfield(opts,'fracs'), ...
        opts.fracs = 0.10:0.05:0.90; end      % 扫描位置（相对轴框宽度）
    if ~isfield(opts,'bandHalf'), opts.bandHalf = 0.008; end  % 竖条半宽（占宽度）
    if ~isfield(opts,'minSpan'),  opts.minSpan = 0.35; end    % 至少横跨轴宽的 35%
    if ~isfield(opts,'tolY'),     opts.tolY = 14; end         % 纵向关联容差(px)
    if ~isfield(opts,'tolC'),     opts.tolC = 60; end         % 颜色关联容差
    if ~isfield(opts,'minPix'),   opts.minPix = 25; end

    cand = struct('color', {}, 'size', {}, 'seed', {}, 'yMean', {}, 'spanX', {});

    D = double(I);
    [H, W, ~] = size(D);
    if size(D,3) < 3, return; end

    r0 = max(1, round(ax.rowTop)+2);  r1 = min(H, round(ax.rowBottom)-2);
    c0 = max(1, round(ax.colLeft)+2); c1 = min(W, round(ax.colRight)-2);
    if r1 <= r0 || c1 <= c0, return; end

    % 彩色像素掩膜：有饱和度、不是过亮背景
    mxv = max(D,[],3); mnv = min(D,[],3);
    satA = mxv - mnv;
    lumA = 0.299*D(:,:,1) + 0.587*D(:,:,2) + 0.114*D(:,:,3);
    % 彩色像素（有饱和度） 或 深色像素（黑 / 深灰曲线）
    %   只取彩色像素时，纯黑曲线会被整条漏掉（合成基准场景 F 实测：
    %     真值 2 条只找到 1 条）。黑色曲线的唯一线索是"暗"，所以要把
    %     深色像素也算进来，靠后续的"按颜色分层"把它和深绿分开。
    isColor = ((satA >= 45) & (lumA <= 242)) | (lumA < 120);

    % 每层一张"彩色掩膜"和"颜色查表"，避免反复 reshape 大图
    [ii, jj] = find(isColor);
    if isempty(ii), return; end
    pixRGB = zeros(numel(ii), 3);
    for ch = 1:3
        chD = D(:,:,ch);
        pixRGB(:,ch) = chD(isColor);
    end
    % 只保留轴框内的
    inbox = ii >= r0 & ii <= r1 & jj >= c0 & jj <= c1;
    ii = ii(inbox); jj = jj(inbox); pixRGB = pixRGB(inbox,:);
    if isempty(ii), return; end

    halfw = max(2, round(opts.bandHalf*(c1-c0)));

    % ---------- 第一步：每个位置数竖条簇 ----------
    scans = {};   % 每个位置: struct('x', c, 'clusters', struct array)
    for fi = 1:numel(opts.fracs)
        cc = round(c0 + opts.fracs(fi)*(c1-c0));
        cl = colsClusters(ii, jj, pixRGB, r0, r1, cc-halfw, cc+halfw, opts.minPix/2);
        if ~isempty(cl), scans{end+1} = struct('x', cc, 'clusters', cl); end %#ok<AGROW>
    end
    if isempty(scans), return; end

    % ---------- 第二步：跨位置关联成曲线 ----------
    % 每条"曲线"是一个跨位置簇序列：tracks{t} = struct array of clusters
    tracks = {};
    for si = 1:numel(scans)
        sc = scans{si};
        usedC = false(1, numel(sc.clusters));
        for ti = 1:numel(tracks)
            tr = tracks{ti};
            last = tr(end);
            if sc.x <= last.x, continue; end      % 只向前接
            best = 0; bestD = inf;
            for ci = 1:numel(sc.clusters)
                if usedC(ci), continue; end
                c = sc.clusters(ci);
                dc = norm(c.color - last.color);
                dy = abs(c.y - last.y);
                if dc > opts.tolC || dy > opts.tolY, continue; end
                d = dc/opts.tolC + dy/opts.tolY;
                if d < bestD, bestD = d; best = ci; end
            end
            if best > 0
                tr(end+1) = sc.clusters(best); %#ok<AGROW>
                tracks{ti} = tr;
                usedC(best) = true;
            end
        end
        % 没接上的簇开新轨
        for ci = 1:numel(sc.clusters)
            if usedC(ci), continue; end
            tracks{end+1} = sc.clusters(ci); %#ok<AGROW>
        end
    end

    % ---------- 第三步：只接受"横跨足够宽"的轨迹 ----------
    minSpanPx = opts.minSpan*(c1-c0);
    for ti = 1:numel(tracks)
        tr = tracks{ti};
        if numel(tr) < 3, continue; end
        span = tr(end).x - tr(1).x;
        if span < minSpanPx, continue; end
        % 颜色取该轨迹各段的中位（抗抗锯齿偏色）
        cols = reshape([tr.color], 3, [])';
        col = median(cols, 1);
        if max(col) - min(col) < 35, continue; end
        npx = sum([tr.n]);
        if npx < opts.minPix, continue; end
        % 种子点：取该轨迹中"竖条最窄"的那一段（最不像交叉/重叠处）。
        %   但"最窄"往往落在多条曲线的汇聚处（Fig.3D 的 9 条 V 形族全在
        %     x≈0 汇聚成一条竖线，最窄段就在那里）—— 种子落在汇聚点，
        %     DP 无法区分自己那条，只能提到一条。
        %   所以加一条：优先取"本轨迹各段里、与本位置其它轨迹纵向距离最大"
        %   的那一段，也就是分得最开的位置。
        [~, bi] = min([tr.n]);
        if numel(tr) >= 5
            % 在该轨迹自身的纵向变化范围内，找"离其它轨迹最远"的段
            bestSep = -inf; bj = bi;
            for j = 1:numel(tr)
                sep = inf;
                for t2 = 1:numel(tracks)
                    if t2 == ti, continue; end
                    tr2 = tracks{t2};
                    dd = abs(arrayfun(@(s) s.x, tr2) - tr(j).x);
                    if isempty(dd) || min(dd) > 20, continue; end
                    yy = arrayfun(@(s) s.y, tr2);
                    sep = min(sep, min(abs(yy - tr(j).y)));
                end
                if isfinite(sep) && sep > bestSep
                    bestSep = sep; bj = j;
                end
            end
            if isfinite(bestSep) && bestSep > 0, bi = bj; end
        end
        cand(end+1) = struct('color', col, 'size', npx, ...
            'seed', [tr(bi).x, round(tr(bi).y)], ...
            'yMean', mean([tr.y]), 'spanX', span); %#ok<AGROW>
    end

    % ---------- 第四步：合并重复（同一曲线被分成两轨）----------
    if numel(cand) > 1
        keep = true(1, numel(cand));
        [~, o] = sort([cand.size], 'descend');
        for a = 1:numel(o)
            ia = o(a);
            if ~keep(ia), continue; end
            for b = a+1:numel(o)
                ib = o(b);
                if ~keep(ib), continue; end
                dc = norm(double(cand(ia).color) - double(cand(ib).color));
                dy = abs(cand(ia).yMean - cand(ib).yMean);
                if dc < 45 && dy < 10, keep(ib) = false; end
            end
        end
        cand = cand(keep);
    end

    % 按纵向位置排序
    if ~isempty(cand)
        [~, o] = sort([cand.yMean]);
        cand = cand(o);
    end
end

%
function cl = colsClusters(ii, jj, pixRGB, r0, r1, ca, cb, minPix)
%COLSCLUSTERS  在列区间 [ca,cb] 内找"彩色竖条"簇
%
%   两步走：先按行连通分簇，再在簇内按颜色细分。
%   为什么不是反过来（先全局按颜色分层）：
%     Fig.3F 的深绿 [0 85 0] 与浅绿 [0 255 0] 差得很远，可以全局分层；
%     但抗锯齿会把同一条线糊出很宽的颜色分布，全局先分层会把一条曲线
%     切碎成多层，于是同一条曲线冒出好几个候选。
%   为什么不能只按行连通（老做法）：
%     两条不同深浅的曲线在陡段上纵向重叠，行连通会把它们并成"一簇"，
%     颜色取平均后变成中间色（实测 Fig.3F 得到 [34 187 34]），
%     两条曲线于是只剩一条候选。
%   所以：行连通先把空间上分开的分开；再在同一个连通簇内部按颜色
%   细分 —— 细分只在"颜色确实分成两拨"时发生，不会把一条线切碎。
    sel = jj >= ca & jj <= cb;
    if nnz(sel) < minPix, cl = []; return; end
    rows = ii(sel); cols3 = pixRGB(sel,:);

    cl = struct('x', {}, 'y', {}, 'color', {}, 'n', {});

    present = false(r1-r0+1, 1);
    present(rows - r0 + 1) = true;
    d = diff([false; present; false]);
    ss = find(d == 1); ee = find(d == -1) - 1;

    for k = 1:numel(ss)
        ra = r0 + ss(k) - 1;  rb = r0 + ee(k) - 1;
        m = rows >= ra & rows <= rb;
        if nnz(m) < minPix, continue; end
        sub = cols3(m,:);
        subRows = rows(m);

        % 在该连通簇内部按颜色细分（返回的是各子集的索引）
        groups = splitByColor(sub);
        % ---- 挑"核心色带"，丢掉抗锯齿晕 ----
        %   基准测试抓到的关键问题：抗锯齿把曲线糊成"核心色 + 一圈晕"，
        %     晕的颜色是核心色与白底的混合（如核心 [0 255 0] 的晕
        %     [179 255 179]）。按中位色给候选时，取到的是晕的颜色，
        %     于是同一条曲线被拆成好几个候选（实测真值 3 条报出 8 条）。
        %   判据：核心带是"最饱和 / 最暗"的那一带，且它占簇内像素的
        %   一定比例（>= 25%）；占比较小的都是晕，直接并到核心带里。
        if numel(groups) > 1
            score = zeros(1, numel(groups));
            nPix  = zeros(1, numel(groups));
            for g = 1:numel(groups)
                gi = groups{g}; nPix(g) = numel(gi);
                cm = median(sub(gi,:), 1);
                sat = max(cm) - min(cm);          % 饱和度高 = 更接近核心色
                lum = 0.299*cm(1) + 0.587*cm(2) + 0.114*cm(3);
                score(g) = sat - 0.25*lum;        % 越饱和、越暗越像核心
            end
            [~, coreG] = max(score);
            keep = nPix >= 0.25*sum(nPix);
            if any(keep)
                core = find(keep);
                merged = vertcat(groups{core});
                groups = {merged};
            else
                groups = groups(coreG);
            end
        end
        for g = 1:numel(groups)
            gi = groups{g};
            if numel(gi) < minPix, continue; end
            col = median(sub(gi,:), 1);
            if max(col) - min(col) < 30, continue; end
            cl(end+1) = struct('x', mean([ca cb]), 'y', mean(subRows(gi)), ...
                               'color', col, 'n', numel(gi)); %#ok<AGROW>
        end
    end
end

%
function groups = splitByColor(pix)
%SPLITBYCOLOR  把一组像素按颜色分成 1~3 个子集
%
%   做法：先找"离整体中位色最远"的那个像素当第二个中心，再看最近的像素
%   离它多远；只有确实分得开（最大通道差 > 55）才真分成两拨。
%   这样"一条线（含抗锯齿）"不会被切开，而"两条不同深浅的线"会被分开。
    n = size(pix, 1);
    groups = {1:n};
    if n < 30, return; end
    c1 = median(pix, 1);
    d1 = max(abs(pix - c1), [], 2);
    [~, far] = max(d1);
    c2 = pix(far, :);
    dc12 = max(abs(c1 - c2));
    if dc12 <= 55, return; end          % 分不开，保持一组

    idx = zeros(n,1);
    for i = 1:n
        e1 = max(abs(pix(i,:) - c1));
        e2 = max(abs(pix(i,:) - c2));
        idx(i) = 1 + (e2 < e1);
    end
    % 若某一拨太小，视为抗锯齿杂色，不切
    if nnz(idx==1) < 0.15*n || nnz(idx==2) < 0.15*n, return; end
    groups = {find(idx==1), find(idx==2)};
end
