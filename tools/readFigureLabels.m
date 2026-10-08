function info = readFigureLabels(I, ax, opts)
%READFIGURELABELS  从图里读出"坐标轴名称/单位"和"图例条目"，供导出时标注数据。
%
%   用法: info = readFigureLabels(I, ax)
%     I  : 图像；ax : 轴框结构体
%
%   返回 info:
%     info.ocr        - ocrBridge 的原始结果
%     info.axis       - 坐标轴标签
%         .x.title / .x.unit      水平轴（图下方）的标题与单位
%         .y.title / .y.unit      竖直轴（图左侧或右侧）的标题与单位
%     info.legend     - 图例结构体数组，字段 name / color / box / yCenter
%     info.units      - 从轴标签里解析出的单位 cell 数组
%     info.notes      - 过程说明
%
%   设计说明：
%     轴标签在图框**外面**，图例在图框**里面** —— 用这个位置关系区分，
%     比按字号区分可靠得多。竖直轴标签通常是旋转 90° 的，OCR 会把它拆成
%     一堆竖排单词，这里按"词数>=3 且纵向跨度大"识别并合并。
%
%   ★ 性能设计：所有需要 OCR 的区域（刻度带、轴标题带、图例、图例里的
%     逐行文字）先**收集起来**，最后用 ocrBatch **一次调用**识别完。
%     逐块调用会为每块起一个 PowerShell 进程，端到端要 1~2 分钟；
%     合并后通常 3~8 秒。

    if nargin < 3, opts = struct(); end

    info = struct('ocr', [], 'axis', struct(), 'legend', struct([]), ...
                  'units', {{}}, 'notes', {{}});

    H = size(I,1); W = size(I,2);
    fh = ax.rowBottom - ax.rowTop;
    fw = ax.colRight - ax.colLeft;

    % ---------- 0. 规划所有需要 OCR 的区域 ----------
    % 每块记：裁剪范围 rect、放大倍数 scale、是否二值化、用途 tag（回填用）
    specs = {};   % 每个元素 {rect, scale, binarize, tag}

    % X 轴标题带（在框下方；刻度数字也在这一带里，靠位置区分）
    xBand  = [round(ax.colLeft-0.05*fw), round(ax.rowBottom+1), ...
              round(ax.colRight+0.05*fw), round(min(H, ax.rowBottom+0.42*fh))];
    specs{end+1} = {xBand, 5, true, 'xtitle'};

    % Y 轴标题带：左右都试（旋转 90° 的文字整条带一起识别更好）
    yBandL = [round(max(1,ax.colLeft-0.30*fw)), round(max(1,ax.rowTop-0.05*fh)), ...
              round(ax.colLeft-1), round(min(H,ax.rowBottom+0.05*fh))];
    yBandR = [round(ax.colRight+1), round(max(1,ax.rowTop-0.05*fh)), ...
              round(min(W,ax.colRight+0.30*fw)), round(min(H,ax.rowBottom+0.05*fh))];
    if yBandL(3) > yBandL(1)+5, specs{end+1} = {yBandL, 5, true, 'ytitleL'}; end
    if yBandR(3) > yBandR(1)+5, specs{end+1} = {yBandR, 5, true, 'ytitleR'}; end

    % 图例框整块
    leg = findLegend(I, ax);
    if leg.found && ~isempty(leg.boxes)
        specs{end+1} = {leg.rect, 4, true, 'legend'};
    else
        info.notes{end+1} = '未找到图例框（该图可能没有图例，或图例无边框）';
    end

    % ---------- 1. 一次批量 OCR ----------
    emptyItems = struct('text',{},'x',{},'y',{},'w',{},'h',{});
    xItems = emptyItems; yItemsL = emptyItems; yItemsR = emptyItems; emb = emptyItems;

    if isempty(specs)
        info.axis = struct('x', struct('title','','unit','','raw',''), ...
                           'y', struct('title','','unit','','raw',''));
        info.ocr = struct('engine','none','note','没有可识别的区域');
        return;
    end

    regions = struct('I', {}, 'scale', {}, 'binarize', {});
    for k = 1:numel(specs)
        sp = specs{k};
        regions(k).I = cropRect(I, sp{1});
        regions(k).scale = sp{2};
        regions(k).binarize = sp{3};
    end
    res = ocrBatch(regions);

    % ---------- 2. 回填：把每块结果搬到整图坐标 ----------
    info.ocr = struct('engine', '', 'note', '按分区裁剪识别（一次批量调用）');
    for k = 1:numel(specs)
        if ~isempty(res(k).engine), info.ocr.engine = res(k).engine; end
        it = res(k).items;
        for m = 1:numel(it)
            it(m).x = it(m).x + specs{k}{1}(1) - 1;
            it(m).y = it(m).y + specs{k}{1}(2) - 1;
        end
        switch specs{k}{4}
            case 'xtitle',  xItems = it;
            case 'ytitleL', yItemsL = it;
            case 'ytitleR', yItemsR = it;
            case 'legend',  emb = it;
        end
    end

    xlab = buildAxisLabel(xItems, 'h');
    ylab = buildAxisLabel(yItemsL, 'v');
    if isempty(ylab.title)
        ylabR = buildAxisLabel(yItemsR, 'v');
        if ~isempty(ylabR.title), ylab = ylabR; end
    end
    info.axis = struct('x', xlab, 'y', ylab);

    % ---------- 3. 图例文字与样本配对 ----------
    if leg.found && ~isempty(leg.boxes)
        if numel(emb) < 2
            info.notes{end+1} = '图例区域没识别到足够文字，名称可手填';
        end
        info.legend = matchLegend(leg.boxes, leg.colors, emb);
        if isempty(info.legend) && ~isempty(emb)
            info.notes{end+1} = '找到图例框但没能把文字与样本对应起来';
        end
    end

    % ---------- 4. 单位汇总 ----------
    u = {};
    if ~isempty(xlab.unit), u{end+1} = xlab.unit; end
    if ~isempty(ylab.unit), u{end+1} = ylab.unit; end
    info.units = u;
end

% =====================================================================
function A = cropRect(I, r)
    A = I(max(1,r(2)):min(size(I,1),r(4)), max(1,r(1)):min(size(I,2),r(3)), :);
end

% =====================================================================
function items = ocrBand(I, band, opts)
%OCRBAND  轴向标题带：优先逐行裁剪后高倍 OCR，失败则整带 OCR 兜底。
%   两种方式各有适用场景（逐行适合小字、整带适合字号较大或排版紧凑的图），
%   都试一遍取词更多的那次，比单选一种稳。
    if ~isfield(opts,'axisScale'), sc = 4; else, sc = opts.axisScale; end
    a = ocrLineByLine(I, band, struct('scale', sc));
    b = ocrBandPlain(I, band, opts);
    if numel(a) >= numel(b)
        items = a;
    else
        items = b;
    end
end

% =====================================================================
function items = ocrBandPlain(I, band, opts)
%OCRBANDPLAIN  直接把整条带裁下来 OCR（适合旋转 90° 的竖直标签）
    x0 = max(1, band(1)); y0 = max(1, band(2));
    x1 = min(size(I,2), band(3)); y1 = min(size(I,1), band(4));
    items = struct('text', {}, 'x', {}, 'y', {}, 'w', {}, 'h', {});
    if x1 <= x0 || y1 <= y0, return; end
    crop = I(y0:y1, x0:x1, :);
    if ~isfield(opts,'axisScale'), sc = 4; else, sc = opts.axisScale; end
    r = ocrBridge(crop, struct('scale', sc, 'pass2', false, 'variants', true, ...
                               'minCharH', 4));
    for k = 1:numel(r.items)
        it = r.items(k);
        it.x = it.x + x0 - 1;
        it.y = it.y + y0 - 1;
        items(end+1) = it; %#ok<AGROW>
    end
end

% =====================================================================
function lab = buildAxisLabel(items, orient)
%BUILDAXISLABEL  从图框附近的一堆词里挑出真正的轴标题，解析其单位。
%   思路：轴标题是"一行/一列连续排列、字号相近"的词。先按行（或按列）聚类，
%   再取最优的那一簇，最后从括号里解析单位。这样能自动排除零散的刻度数字。
    lab = struct('title', '', 'unit', '', 'raw', '');
    if isempty(items), return; end

    xs = [items.x]; ys = [items.y]; ws = [items.w]; hs = [items.h];

    % 按"垂直间隙"分行：把词按行中心排序，相邻行中心间距超过一个行高就断开。
    % 比固定容差聚类稳 —— 不会把相邻的两行文字（标题行 + 单位行）混在一起。
    if strcmp(orient, 'h')
        key = ys + hs/2;  adv = ws;  oth = ys;
    else
        key = xs + ws/2;  adv = hs;  oth = xs;
    end
    lineH = max(6, median(hs));
    [~, ord] = sort(key);
    g = zeros(size(key));
    gid = 1; g(ord(1)) = gid;
    for k = 2:numel(ord)
        if key(ord(k)) - key(ord(k-1)) > 0.75*lineH
            gid = gid + 1;
        end
        g(ord(k)) = gid;
    end

    % 选"最像轴标题"的那一行：优先含字母的（刻度数字全是数字），其次比跨度
    bestScore = -inf; best = [];
    for k = 1:gid
        m = (g == k);
        joined = strjoin({items(m).text}, ' ');
        nLetter = sum(isletter(joined));
        if strcmp(orient, 'h')
            span = max(xs(m)+ws(m)) - min(xs(m));
        else
            span = max(ys(m)+hs(m)) - min(ys(m));
        end
        score = 100*double(nLetter > 0) + nLetter + span/max(1,lineH);
        if score > bestScore
            bestScore = score; best = find(m);
        end
    end
    if isempty(best), return; end

    if strcmp(orient, 'h')
        [~, o] = sort(xs(best));
    else
        [~, o] = sort(ys(best));
    end
    best = best(o);
    words = {items(best).text};
    lab.raw = strjoin(words, ' ');

    s = strjoin(words, ' ');
    tok = regexp(s, '\(([^()]*)\)\s*$', 'tokens', 'once');
    if ~isempty(tok)
        lab.unit = strtrim(tok{1});
        lab.title = strtrim(regexprep(s, '\([^()]*\)\s*$', ''));
    else
        lab.title = strtrim(s);
    end
    lab.title = cleanupUnitText(lab.title);
    lab.unit  = cleanupUnitText(lab.unit);
    lab = dropTickText(lab);
end

% =====================================================================
function s = cleanupUnitText(s)
%CLEANUPUNITTEXT  修正常见 OCR 误识，尤其是上下标
    if isempty(s), return; end
    reps = { ...
        'pm2',   'μm²';  'μm2', 'μm²';  'um2', 'μm²'; ...
        'pm',    'μm';   'um',  'μm';   ...
        '106',   '10⁶';  '105', '10⁵';  '103', '10³'; ...
        'x106',  '×10⁶'; '×106','×10⁶'; 'x105','×10⁵'; ...
        '0PL',   'OPL';  'Ph0ton','Photon'; 'SLope','Slope'; ...
        'pmol',  'μmol'};
    for k = 1:size(reps,1)
        s = strrep(s, reps{k,1}, reps{k,2});
    end
    s = regexprep(s, '\s+', ' ');
    s = strtrim(s);
end

% =====================================================================
function lab = dropTickText(lab)
%DROPTICKTEXT  如果拼出来的"标题"其实是刻度数字，就丢掉
    if isempty(lab.title), return; end
    t = lab.title;
    if isempty(regexp(t, '[A-Za-z]', 'once'))       % 完全没有字母 -> 是数字
        lab.title = '';
        lab.raw = '';
    end
end

% =====================================================================
function leg = matchLegend(boxes, colors, items)
%MATCHLEGEND  把图例样本与它右侧/下方的文字对应起来
    leg = struct('name', {}, 'color', {}, 'box', {}, 'yCenter', {});
    if isempty(boxes), return; end
    n = size(boxes,1);

    % 记录已被占用的词，避免两行共用同一个词
    used = false(1, numel(items));
    % 按 y 排序处理，保证同一行的样本先配到同一行的文字
    [~, ord] = sort(boxes(:,2));
    for k = ord(:)'
        cy = mean(boxes(k,[2 4]));
        cx = boxes(k,3);                       % 样本右端
        % 找同一行、在样本右侧的词
        cand = [];
        for m = 1:numel(items)
            if used(m), continue; end
            yc = items(m).y + items(m).h/2;
            if abs(yc - cy) <= max(10, 0.8*items(m).h) && items(m).x >= cx - 4
                cand(end+1) = m; %#ok<AGROW>
            end
        end
        if isempty(cand), continue; end
        [~, o2] = sort([items(cand).x]);
        cand = cand(o2);
        % 只取与第一个词横向相邻的连续若干词（同一行的标签）
        sel = cand(1);
        for q = 2:numel(cand)
            rightEdge = items(sel(end)).x + items(sel(end)).w;
            if items(cand(q)).x - rightEdge <= 2.0*items(sel(end)).h
                sel(end+1) = cand(q); %#ok<AGROW>
            else
                break;
            end
        end
        used(sel) = true;
        leg(end+1) = struct('name', strjoin({items(sel).text}, ' '), ...
                            'color', colors(k,:), ...
                            'box', boxes(k,:), ...
                            'yCenter', cy); %#ok<AGROW>
    end

    % 按 y 排序，与图例自上而下的顺序一致
    if ~isempty(leg)
        [~, o] = sort([leg.yCenter]);
        leg = leg(o);
    end
end
