function cand = scanBySlices(I, ax, opts)
%SCANBYSLICES  按"列切片"找出同色系多条曲线，给出一条一个种子点。
%
%   为什么不用单纯的多位置扫描（scanCurveCandidates）：
%   同色系曲线在一端常常汇聚到一起（例如 Fig.3A 里 9 条绿线在 x=0 附近
%   全挤在 0~50 nm 内）。多位置扫描把"相邻 14 px 内的簇"当成同一条，
%   于是汇聚区的多条会被并成一条，还混出一个"颜色是平均值"的假候选
%   （实测出现过 RGB[68 196 68]、3831 px 的假候选）。
%
%   本函数换一个更贴近"人怎么看"的做法：
%     1) 找一个曲线分得最开的列（而不是固定比例位置）；
%     2) 把该列切成若干"细游程"（细 = 曲线，粗 = 标记/误差棒/文字）；
%     3) 每个游程的中心色就是一个目标色；用"颜色接近 + 纵向连续"
%        把相邻列的同一条曲线连起来（不是靠固定容差把邻近的并掉）。
%
%   返回 cand(k)：.color / .seed / .size / .yMean / .spanX / .from='slice'

    if nargin < 3, opts = struct(); end
    if ~isfield(opts,'maxCurves'), opts.maxCurves = 16; end
    if ~isfield(opts,'minSat'),    opts.minSat = 30; end      % 彩色像素的最低饱和度
    if ~isfield(opts,'thinMax'),   opts.thinMax = 9; end      % "细游程"最大厚度 = 线宽
    if ~isfield(opts,'tolC'),      opts.tolC = 26; end        % 同一条曲线的颜色容差
    if ~isfield(opts,'maxJump'),   opts.maxJump = 10; end     % 相邻列允许的纵向跳变
    if ~isfield(opts,'minLen'),    opts.minLen = 0.30; end    % 至少占轴宽的 30%
    if ~isfield(opts,'darkFirst'), opts.darkFirst = true; end

    cand = struct('color', {}, 'size', {}, 'seed', {}, 'yMean', {}, ...
                  'spanX', {}, 'from', {});

    D = double(I);
    [H, W, ~] = size(D);
    if size(D,3) < 3, return; end
    r0 = max(1, round(ax.rowTop)+2);  r1 = min(H, round(ax.rowBottom)-2);
    c0 = max(1, round(ax.colLeft)+2); c1 = min(W, round(ax.colRight)-2);
    if r1 <= r0+4 || c1 <= c0+4, return; end

    R = D(:,:,1); G = D(:,:,2); B = D(:,:,3);
    mx = max(D,[],3); mn = min(D,[],3);
    sat = mx - mn;
    lum = 0.299*R + 0.587*G + 0.114*B;
    isCurvePix = (sat >= opts.minSat) & (lum <= 245);

    spanCols = c1 - c0 + 1;

    % ---------- 1. 逐列切出"细游程" ----------
    runs = cell(1, spanCols);      % runs{i} = struct('y','color','n')
    for i = 1:spanCols
        c = c0 + i - 1;
        colMask = isCurvePix(r0:r1, c);
        if ~any(colMask), continue; end
        v = colMask(:)';
        e = diff([false, v, false]);
        ss = find(e==1); ee = find(e==-1)-1;
        lst = struct('y', {}, 'color', {}, 'n', {});
        for k = 1:numel(ss)
            w = ee(k)-ss(k)+1;
            if w > opts.thinMax, continue; end       % 太厚：不是线
            rows = ss(k):ee(k);
            pk = zeros(numel(rows),3);
            for q = 1:numel(rows)
                pk(q,:) = [R(r0+rows(q)-1,c), G(r0+rows(q)-1,c), B(r0+rows(q)-1,c)];
            end
            lst(end+1) = struct('y', mean(rows)+r0-1, ...
                                'color', mean(pk,1), 'n', w); %#ok<AGROW>
        end
        if ~isempty(lst), runs{i} = lst; end
    end

    % ---------- 2. 找"最分得开"的列当种子列 ----------
    bestI = 0; bestScore = -inf;
    for i = 1:spanCols
        lst = runs{i};
        if numel(lst) < 2, continue; end
        ys = sort([lst.y]);
        gaps = diff(ys);
        % 评分：条数多、且最小间距大（说明这一列各条分得开）
        sc = numel(lst) + 0.5*min(gaps)/10;
        if sc > bestScore, bestScore = sc; bestI = i; end
    end
    if bestI == 0, return; end
    seeds = runs{bestI};
    if numel(seeds) > opts.maxCurves
        seeds = seeds(1:opts.maxCurves);
    end
    if opts.darkFirst
        [~, o] = sort(arrayfun(@(s) mean(s.color), seeds));   % 深的在前
        seeds = seeds(o);
    end

    % ---------- 3. 每个种子：向左右按"颜色 + 纵向连续"延伸，量出跨度 ----------
    for k = 1:numel(seeds)
        colK = seeds(k).color;
        seedY = seeds(k).y;
        seedC = c0 + bestI - 1;
        spanL = seedC; spanR = seedC;
        nPix = seeds(k).n;
        for dir = [-1 1]
            yRef = seedY; cRef = colK; lastY = seedY;
            miss = 0;
            c = seedC;
            while true
                c = c + dir;
                if c < c0 || c > c1, break; end
                i2 = c - c0 + 1;
                lst = runs{i2};
                if isempty(lst)
                    miss = miss + 1;
                    if miss > 6, break; end
                    continue;
                end
                best = 0; bestD = inf;
                for q = 1:numel(lst)
                    dc = norm(lst(q).color - cRef);
                    dy = abs(lst(q).y - lastY);
                    if dc > opts.tolC || dy > opts.maxJump, continue; end
                    d = dc/opts.tolC + dy/opts.maxJump;
                    if d < bestD, bestD = d; best = q; end
                end
                if best == 0
                    miss = miss + 1;
                    if miss > 6, break; end
                    continue;
                end
                miss = 0;
                lastY = lst(best).y;
                % 颜色参考缓慢跟随，适应沿线渐变
                cRef = 0.8*cRef + 0.2*lst(best).color;
                nPix = nPix + lst(best).n;
                if dir < 0, spanL = c; else, spanR = c; end
            end
        end
        span = spanR - spanL;
        if span < opts.minLen * spanCols, continue; end
        cand(end+1) = struct('color', colK, 'size', nPix, ...
            'seed', [seedC, seedY], 'yMean', seedY, ...
            'spanX', span, 'from', 'slice'); %#ok<AGROW>
    end

    % ---------- 4. 去掉颜色/位置都几乎相同的重复 ----------
    if numel(cand) > 1
        keep = true(1, numel(cand));
        for a = 1:numel(cand)
            if ~keep(a), continue; end
            for b = a+1:numel(cand)
                if ~keep(b), continue; end
                if norm(cand(a).color - cand(b).color) < 18 && ...
                   abs(cand(a).seed(2) - cand(b).seed(2)) < 6
                    keep(b) = false;
                end
            end
        end
        cand = cand(keep);
    end
    if ~isempty(cand)
        [~, o] = sort([cand.yMean]);
        cand = cand(o);
    end
end
