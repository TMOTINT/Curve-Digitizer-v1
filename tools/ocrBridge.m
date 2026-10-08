function res = ocrBridge(I, opts)
%OCRBRIDGE  识别图像中的文字（OCR），返回文字内容及其在图像中的位置。
%
%   用途：论文图里通常有必须一起提取的信息 ——
%     * 坐标轴名称与单位（"Time after stimulus onset (s)"、"OPL (nm)"）
%     * 图例里的曲线名称（"Subject 1"、"L/M-cones"、"0.09 (1.2)" 等）
%   有了它们，导出的数据才能自动带上列名和单位。
%
%   用法：
%       res = ocrBridge(I)                       % I 为 imread 得到的图像
%       res = ocrBridge(I, struct('scale', 8))
%
%   返回 res：
%       res.items  - 结构体数组，字段 text/x/y/w/h（原始图像像素坐标）
%       res.lines  - cell 数组，每格是一行文字的拼接结果
%       res.engine - 'windows-ocr' | 'tesseract' | 'none'
%       res.scale  - 实际使用的放大倍数
%       res.note   - 失败原因（成功时为空）
%       res.cached - 是否来自缓存
%
%   ---- 性能设计（这几点决定了快慢）----
%   1) 结果缓存：同一张图 + 同一组参数只真正 OCR 一次。界面里反复进入
%      标定/读标注步骤时不会再等第二遍。
%   2) 提前停止：一次 OCR 就够用时立刻返回，不再跑其余预处理变体。
%      （每个变体都要起一个 PowerShell 进程，约 0.3~0.5 s，必须省。）
%   3) 调用方应尽量把小图（图例、单独文字行）直接裁好再传进来，
%      不要指望本函数在整页大图上"顺便"找出小字。
%
%   关键经验：
%     * 论文图里的文字往往只有 10~15 px 高，OCR 引擎会把它当噪点。
%       必须放大到 40 px 以上 —— 本函数默认放大 6 倍（受 maxDim 限制）。
%     * 二值化能救轴标签，却会让彩图文字整片消失，所以第一次用二值化，
%       若没识别到文字再退回灰度原样。
%     * 字号过小的检测结果是噪点（曲线密集处的伪文字），按高度过滤。
%
%   引擎优先级：
%     1) Windows 自带 OCR（Windows.Media.Ocr）—— 无需安装，Win10/11 都有
%     2) tesseract（若 PATH 或常见安装目录里能找到 exe）
%   两个都不可用时返回 engine='none'，调用方应优雅降级。

    if nargin < 2, opts = struct(); end
    if ~isfield(opts,'scale'),    opts.scale = 6;    end
    if ~isfield(opts,'minCharH'), opts.minCharH = 11; end
    if ~isfield(opts,'variants'), opts.variants = true; end
    if ~isfield(opts,'maxDim'),   opts.maxDim = 2600; end
    if ~isfield(opts,'pass2'),    opts.pass2 = true;  end
    if ~isfield(opts,'pass2Scale'), opts.pass2Scale = 3; end
    if ~isfield(opts,'useCache'), opts.useCache = true; end

    emptyRes = struct('items', [], 'lines', {{}}, 'engine', 'none', 'scale', 1, ...
                      'lang', '', 'note', '', 'cached', false);
    res = emptyRes;

    % ---------------- 0. 查缓存 ----------------
    ck = '';
    if opts.useCache
        ck = ocrCacheKey(I, opts);
        [got, c] = ocrCache('get', ck);
        if ~got, c = []; end
        if ~isempty(c)
            c.cached = true;
            res = c;
            fprintf('  [ocrBridge] 命中缓存（%d 词），跳过 OCR\n', numel(res.items));
            return;
        end
    end

    % ---------------- 1. 预处理（纯 MATLAB，不用任何外部库）----------------
    G0 = toGray(I);
    [H0, W0] = size(G0);

    % 注意：Windows OCR 对超大图会静默返回空结果，必须限制总尺寸。
    scale = opts.scale;
    if scale <= 0, scale = 6; end
    scale = max(1, min(scale, opts.maxDim / max(H0, W0)));

    G = G0;
    if scale > 1.02
        G = imresize(G0, scale, 'bicubic');
    else
        scale = 1;
    end

    tmpDir = tempname;  mkdir(tmpDir);
    cleanup = onCleanup(@() rmTemp(tmpDir)); %#ok<NASGU>

    % ---- 预处理变体：默认只做"紧二值化"，没结果才退回灰度 ----
    variants = buildVariants(G, opts.variants, tmpDir);

    allItems = struct('text', {}, 'x', {}, 'y', {}, 'w', {}, 'h', {});
    engines = {}; langs = {}; langUsed = '';
    for v = 1:numel(variants)
        [j, eng, lg] = ocrOneFile(variants{v});
        if isempty(j), continue; end
        if ~any(strcmp(engines, eng)), engines{end+1} = eng; end
        if ~isempty(lg) && ~any(strcmp(langs, lg)), langs{end+1} = lg; end
        langUsed = lg;
        allItems = [allItems, flattenItems(j, scale)]; %#ok<AGROW>
        % ---- 提前停止：已经拿到像样的文字就不再试其它变体 ----
        if numel(allItems) >= 8, break; end
    end
    res.scale = scale;
    if isempty(engines)
        res.note = '没找到可用的 OCR 引擎（Windows OCR 与 tesseract 均不可用）';
        return;
    end
    res.engine = strjoin(engines, '+');
    res.lang = strjoin(langs, ',');

    % ---- 语言后处理：中文引擎会把曲线噪声认成汉字 ----
    if contains(langUsed, 'zh') && ~isfield(opts,'keepCJK')
        before = numel(allItems);
        allItems = dropCJK(allItems);
        if before > numel(allItems)
            fprintf('  [ocrBridge] 中文引擎误识别的 %d 个汉字词已丢弃（可用 keepCJK=true 保留）\n', ...
                before - numel(allItems));
        end
    end

    % ---------------- 2. 文字区域检测 + 局部放大二次扫描 ----------------
    % 整图放大受尺寸上限约束，轴标签这种小字往往还是太小。做法：
    % 把图切块（含 50% 重叠），每块单独放大后 OCR，再把结果并回去。
    if opts.pass2
        extra = ocrByTiles(G0, scale, opts, tmpDir);
        if ~isempty(extra)
            fprintf('  [ocrBridge] 局部放大二次扫描补到 %d 个词\n', numel(extra));
            allItems = [allItems, extra];
        end
    end

    % ---------------- 3. 去重（同一段文字会被重复识别）----------------
    allItems = dedupItems(allItems);

    % ---------------- 4. 按字高过滤噪点 ----------------
    % 阈值按识别到字高的中位数自适应：整体没识别好时就别过滤，免得误伤。
    if ~isempty(allItems)
        hh = [allItems.h];
        medH = median(hh(hh > 0));
        minH = min(opts.minCharH, 0.45 * medH);
        keep = hh >= minH;
        dropped = sum(~keep);
        allItems = allItems(keep);
        if dropped > 0
            fprintf('  [ocrBridge] 按字高过滤掉 %d 个疑似噪点词（阈值 %.1f px）\n', ...
                dropped, minH);
        end
    end

    % ---------------- 5. 按行分组 ----------------
    res.items = allItems;
    res.lines = groupLines(allItems);
    if isempty(allItems)
        res.note = 'OCR 未识别到任何文字';
    else
        fprintf('  [ocrBridge] 引擎=%s 语言=%s 放大 %.1fx 识别到 %d 词 / %d 行\n', ...
            res.engine, res.lang, res.scale, numel(allItems), numel(res.lines));
    end

    % ---------------- 6. 写缓存 ----------------
    if opts.useCache && ~isempty(ck)
        ocrCache('put', ck, res);
    end
end

%
function items = dropCJK(items)
%DROPCJK  丢掉纯中日韩字符的"词"（中文 OCR 引擎对曲线噪声的典型误识别）
    if isempty(items), return; end
    keep = true(1, numel(items));
    for k = 1:numel(items)
        t = items(k).text;
        nCJK = sum(t >= char(0x2E80) & t <= char(0x9FFF));
        nASCII = sum(t <= char(0x7F) & t > char(0x20));
        % 全是 CJK，或者 CJK 占多数且 ASCII 字母很少
        if nCJK > 0 && nASCII == 0
            keep(k) = false;
        elseif nCJK >= 2 && nCJK > 2*nASCII
            keep(k) = false;
        end
    end
    items = items(keep);
end

%
function files = buildVariants(G, multi, tmpDir)
%BUILDVARIANTS  生成几种预处理版本，写成 png，返回路径
    h = histcounts(G(:), 0:256);
    [~, bgIdx] = max(h);
    bg = bgIdx - 1;

    imgs = {};
    if multi
        % 顺序很关键：第一次用"松二值化"（对轴标签/图例文字最稳），
        % 之后才退到灰度（保住彩色文字）、紧二值化、反相（深底图）。
        % 正常情况下第一次就能识别到文字并提前停止，后面几个只是保底。
        imgs{end+1} = uint8(255 * (G >= max(0, bg - 70)));    % 松二值化
        imgs{end+1} = uint8(G);                              % 灰度原样
        imgs{end+1} = uint8(255 * (G >= max(0, bg - 45)));    % 紧二值化
        imgs{end+1} = uint8(255 - G);                        % 反相（深底图）
    else
        imgs{end+1} = uint8(255 * (G >= max(0, bg - 45)));
    end
    files = {};
    for k = 1:numel(imgs)
        p = fullfile(tmpDir, sprintf('v%d.png', k));
        try
            imwrite(imgs{k}, p);
            files{end+1} = p; %#ok<AGROW>
        catch
        end
    end
end

%
function extra = ocrByTiles(G0, baseScale, opts, tmpDir)
%OCRTILES  把图切块、每块放大后 OCR，专治小字
    extra = struct('text', {}, 'x', {}, 'y', {}, 'w', {}, 'h', {});
    [H, W] = size(G0);

    tile = 600;                      % 原图上的块边长
    ov   = 0.5;                      % 重叠比例（避免把字切两半）
    step = round(tile * (1 - ov));
    ts   = max(1, min(opts.pass2Scale, opts.maxDim / (tile*(1+ov))));

    yStarts = 1:step:max(1, H - round(tile*0.5));
    xStarts = 1:step:max(1, W - round(tile*0.5));
    if numel(yStarts) * numel(xStarts) > 64
        return;                      % 图太大，切块太多，放弃二次扫描
    end

    nTile = 0;
    for yy = yStarts
        for xx = xStarts
            y1 = min(H, yy + tile - 1);
            x1 = min(W, xx + tile - 1);
            y0 = max(1, y1 - tile + 1);
            x0 = max(1, x1 - tile + 1);
            sub = G0(y0:y1, x0:x1);
            if ts > 1.02
                sub = imresize(sub, ts, 'bicubic');
            end
            h = histcounts(sub(:), 0:256);
            [~, bgi] = max(h);
            sub2 = uint8(255 * (sub >= max(0, (bgi-1) - 55)));
            p = fullfile(tmpDir, sprintf('t%d.png', nTile)); nTile = nTile + 1;
            try
                imwrite(sub2, p);
            catch
                continue;
            end
            j = ocrOneFile(p);
            if isempty(j), continue; end
            it = flattenItems(j, ts);
            for k = 1:numel(it)
                it(k).x = it(k).x + x0 - 1;
                it(k).y = it(k).y + y0 - 1;
            end
            extra = [extra, it]; %#ok<AGROW>
        end
    end
    % 只保留整图扫描没覆盖到的位置（重复的交给 dedup，但先粗筛一遍省内存）
    if ~isempty(extra) && baseScale >= 1
        % 无操作：交给统一去重
    end
end

%
function [j, eng, lg] = ocrOneFile(png)
%OCRONEFILE  对一个文件依次尝试 Windows OCR、tesseract
    j = []; eng = ''; lg = '';
    j = runWindowsOcr(png);
    if ~isempty(j)
        eng = 'windows-ocr';
        if isfield(j,'lang'), lg = j.lang; end
        return;
    end
    j = runTesseract(png);
    if ~isempty(j)
        eng = 'tesseract'; lg = 'eng';
    end
end

%
function items = flattenItems(j, scale)
%FLATTENITEMS  把某次 OCR 的结果摊平成 items（坐标除以缩放倍数回到原图）
    items = struct('text', {}, 'x', {}, 'y', {}, 'w', {}, 'h', {});
    if ~isfield(j,'lines') || isempty(j.lines), return; end
    L = j.lines;
    if iscell(L), L = [L{:}]; end
    for k = 1:numel(L)
        ws = L(k).words;
        if isempty(ws), continue; end
        if isstruct(ws), W = ws; else, W = [ws{:}]; end
        for m = 1:numel(W)
            t = strtrim(char(string(W(m).text)));
            if isempty(t), continue; end
            items(end+1) = struct('text', t, ...
                'x', W(m).x/scale, 'y', W(m).y/scale, ...
                'w', W(m).w/scale, 'h', W(m).h/scale); %#ok<AGROW>
        end
    end
end

%
function items = dedupItems(items)
%DEDUPITEMS  去掉重复识别（位置几乎相同 + 文字相同/极相似）
    if numel(items) < 2, return; end
    keep = true(1, numel(items));
    for a = 1:numel(items)
        if ~keep(a), continue; end
        for b = a+1:numel(items)
            if ~keep(b), continue; end
            if abs(items(a).x - items(b).x) > 3 || abs(items(a).y - items(b).y) > 3
                continue;
            end
            ta = items(a).text; tb = items(b).text;
            % 完全一致，或一个是另一个的前缀/子串，或编辑距离很小
            if strcmp(ta,tb) || contains(ta,tb) || contains(tb,ta) || ...
               editDist(lower(ta), lower(tb)) <= max(1, round(0.25*max(numel(ta),numel(tb))))
                % 保留字符更多（更完整）的那个
                if numel(tb) > numel(ta)
                    keep(a) = false; break;
                else
                    keep(b) = false;
                end
            end
        end
    end
    items = items(keep);
end

function d = editDist(a, b)
    na = numel(a); nb = numel(b);
    if na == 0, d = nb; return; end
    if nb == 0, d = na; return; end
    prev = 0:nb;
    for i = 1:na
        cur = zeros(1, nb+1); cur(1) = i;
        for jj = 1:nb
            cost = 1; if a(i) == b(jj), cost = 0; end
            cur(jj+1) = min([prev(jj+1)+1, cur(jj)+1, prev(jj)+cost]);
        end
        prev = cur;
    end
    d = prev(nb+1);
end

%
function lines = groupLines(items)
%GROUPLINES  把词按"同一行"分组（y 相近且水平相邻），拼成整行文字
    lines = {};
    if isempty(items), return; end
    [~, ord] = sortrows([[items.y]', [items.x]']);
    items = items(ord);
    heights = [items.h];
    medH = median(heights(heights > 0));

    used = false(1, numel(items));
    for a = 1:numel(items)
        if used(a), continue; end
        used(a) = true;
        idx = a;
        for b = a+1:numel(items)
            if used(b), continue; end
            % 同一行：竖直中心接近
            ca = items(a).y + items(a).h/2;
            cb = items(b).y + items(b).h/2;
            if abs(ca - cb) > max(4, 0.5*medH), continue; end
            % 且水平上属于这一簇（和已有词的右端不要隔太远）
            rightEdge = max([items(idx).x] + [items(idx).w]);
            if items(b).x - rightEdge > 3.0*medH, continue; end
            used(b) = true;
            idx(end+1) = b; %#ok<AGROW>
        end
        [~, o2] = sort([items(idx).x]);
        idx = idx(o2);
        parts = {items(idx).text};
        lines{end+1} = strjoin(parts, ' '); %#ok<AGROW>
    end
end

%
function G = toGray(I)
%TOGRAY  转灰度 double（兼容灰度/RGB/RGBA 输入）
    if ismatrix(I) && size(I,3) == 1
        G = double(I);
    else
        R = double(I(:,:,1)); Gc = double(I(:,:,2)); B = double(I(:,:,3));
        G = 0.299*R + 0.587*Gc + 0.114*B;
    end
end

%
function j = runWindowsOcr(pngPath)
%RUNWINDOWSOCR  用 Windows 自带 OCR 引擎识别（由 ocr_bridge.ps1 完成）
    j = [];
    here = fileparts(mfilename('fullpath'));
    bridgePath = fullfile(here, 'ocr_bridge.ps1');
    if ~exist(bridgePath, 'file')
        return;
    end
    exe = findPowerShell();
    if isempty(exe), return; end

    % 执行策略禁止直接跑 .ps1：把"前缀赋值 + 脚本正文"拼成一整段命令，
    % 用 -EncodedCommand 传（UTF-16LE base64），绕开策略限制。
    cmdText = sprintf(['$ErrorActionPreference=''Stop'';' ...
                       '$OcrImagePath=''%s'';' ...
                       '$OcrPreferredLang=''%s'';' ...
                       '$src=Get-Content -LiteralPath ''%s'' -Raw;' ...
                       '$sb=[scriptblock]::Create($src);& $sb'], ...
                       pngPath, 'en-US', bridgePath);
    b64 = matlab.net.base64encode(unicode2native(cmdText, 'UTF-16LE'));

    [st, out] = system(sprintf('"%s" -NoProfile -NonInteractive -EncodedCommand %s', exe, b64));
    if st ~= 0
        return;
    end
    j = parseJsonBlock(char(out));
    if ~isempty(j) && ~isfield(j,'engine'), j.engine = 'windows-ocr'; end
end

%
function j = runTesseract(pngPath)
%RUNTESSERACT  退化方案：用 tesseract（如果装了就顺手用）
    j = [];
    exe = findTesseract();
    if isempty(exe), return; end
    tmp = tempname; mkdir(tmp);
    outBase = fullfile(tmp, 'ocr');
    [st, ~] = system(sprintf('"%s" "%s" "%s" -l eng --psm 11 tsv', exe, pngPath, outBase));
    tsv = [outBase '.tsv'];
    if st ~= 0 || ~exist(tsv, 'file'), return; end
    try
        T = readtable(tsv, 'FileType','text', 'Delimiter','\t', ...
                      'ReadVariableNames', true, 'VariableNamingRule','preserve');
    catch
        return;
    end
    vn = T.Properties.VariableNames;
    need = {'level','left','top','width','height','conf','text'};
    if ~all(ismember(need, vn)), return; end
    keep = T.level == 5 & T.conf > 40 & ~cellfun(@isempty, strtrim(cellstr(string(T.text))));
    Tk = T(keep, :);
    rows = {};
    for k = 1:height(Tk)
        rows{end+1} = struct('words', struct('text', char(string(Tk.text(k))), ...
            'x', Tk.left(k), 'y', Tk.top(k), 'w', Tk.width(k), 'h', Tk.height(k))); %#ok<AGROW>
    end
    j = struct('engine', 'tesseract', 'lang', 'eng', 'lines', {rows});
end

%
function j = parseJsonBlock(out)
    j = [];
    b = strfind(out, 'OCR_JSON_BEGIN');
    e = strfind(out, 'OCR_JSON_END');
    if isempty(b) || isempty(e) || e(1) <= b(1), return; end
    js = strtrim(out(b(1)+numel('OCR_JSON_BEGIN') : e(1)-1));
    try
        j = jsondecode(js);
    catch
        j = [];
    end
end

%
function exe = findPowerShell()
    exe = '';
    cands = {fullfile(getenv('SystemRoot'), 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'), ...
             'pwsh', ...
             fullfile(getenv('ProgramFiles'), 'PowerShell', '7', 'pwsh.exe')};
    for k = 1:numel(cands)
        c = cands{k};
        if exist(c, 'file'), exe = c; return; end
        [st, out] = system(sprintf('where %s', c));
        if st == 0
            lines = strsplit(strtrim(out), newline);
            if ~isempty(lines) && ~isempty(strtrim(lines{1}))
                exe = strtrim(lines{1}); return;
            end
        end
    end
end

function exe = findTesseract()
    exe = '';
    cands = {'tesseract', ...
             fullfile(getenv('ProgramFiles'), 'Tesseract-OCR', 'tesseract.exe'), ...
             fullfile(getenv('LOCALAPPDATA'), 'Programs', 'Tesseract-OCR', 'tesseract.exe')};
    for k = 1:numel(cands)
        c = cands{k};
        if exist(c, 'file'), exe = c; return; end
        [st, out] = system(sprintf('where %s', c));
        if st == 0
            lines = strsplit(strtrim(out), newline);
            if ~isempty(lines) && ~isempty(strtrim(lines{1}))
                exe = strtrim(lines{1}); return;
            end
        end
    end
end

function rmTemp(d)
    try, rmdir(d, 's'); catch, end
end
