function results = ocrBatch(regions, opts)
%OCRBATCH  一次调用识别多块区域（批量 OCR），这是省时的关键。
%
%   为什么单独成一个文件：它要被动图读取流程（readFigureLabels）和界面调用，
%   作为公共入口比塞在 ocrBridge.m 里当局部函数更可靠。
%
%   用法：
%       regions = struct('I', {I1,I2,I3}, 'scale', {5,5,4}, ...
%                        'binarize', {true,true,false});
%       results = ocrBatch(regions)
%
%   每个 results(k).items 的坐标是相对该区域左上角的像素坐标，
%   调用方自行叠加偏移。
%
%   为什么必须批量：每起一个 PowerShell 进程要 0.3~0.5 s。一次标定/读标注
%   要处理十几块区域，逐块调用就是十几个进程、几十秒；合并成一次调用后
%   通常 2~5 秒。
%
%   依赖：tools/ocr_bridge.ps1（Windows 自带 OCR 引擎）。

%OCRBRIDGEBATCH  一次调用识别多块区域，大幅省时。
%
%   用途：每起一个 PowerShell 进程要 0.3~0.5 s。一次标定/读标注要
%   处理十几块区域，逐块调用就是十几个进程、几十秒；合并成一次调用后
%   通常只需 2~5 秒。
%
%   用法：
%       regions = struct('I', {I1,I2,I3}, 'scale', {5,5,4}, ...
%                        'binarize', {true,true,false});
%       results = ocrBridgeBatch(regions)
%   每个 results(k).items 的坐标是相对该区域左上角的像素坐标，
%   调用方自行叠加偏移。

    if nargin < 2, opts = struct(); end
    if ~isfield(opts,'useCache'), opts.useCache = true; end
    if ~isfield(opts,'maxDim'),   opts.maxDim = 2600; end

    n = numel(regions);
    results = repmat(struct('items', [], 'engine', '', 'note', '', 'cached', false), 1, n);
    if n == 0, return; end

    tmpDir = tempname; mkdir(tmpDir);
    cleanup = onCleanup(@() rmTemp(tmpDir)); %#ok<NASGU>

    pending = [];   % 需要真正识别的下标
    files = {};     % 对应的临时图
    for k = 1:n
        R = regions(k);
        sc = 5; if isfield(R,'scale') && ~isempty(R.scale), sc = R.scale; end
        bn = true; if isfield(R,'binarize') && ~isempty(R.binarize), bn = R.binarize; end
        [G, sc] = prepForOcr(R.I, sc, bn, opts.maxDim);

        if opts.useCache
            [got, c] = ocrCache('get', ocrCacheKey(R.I, cacheOpts(sc)));
            if ~got, c = []; end
            if ~isempty(c)
                c.cached = true; results(k) = c; continue;
            end
        end
        p = fullfile(tmpDir, sprintf('r%d.png', k));
        try
            imwrite(G, p);
        catch
            results(k).note = '临时写图失败'; continue;
        end
        pending(end+1) = k; %#ok<AGROW>
        files{end+1} = p;   %#ok<AGROW>
    end

    if isempty(pending)
        fprintf('  [ocrBatch] %d 块全部命中缓存\n', n);
        return;
    end

    fprintf('  [ocrBatch] 一次调用识别 %d 块区域…\n', numel(pending));
    t0 = tic;
    j = runWindowsOcrBatch(files);
    if isempty(j), j = runTesseractBatch(files); end
    if isempty(j)
        for q = 1:numel(pending), results(pending(q)).note = '没有可用的 OCR 引擎'; end
        return;
    end

    filesOut = j.files;
    if iscell(filesOut), filesOut = [filesOut{:}]; end
    for q = 1:numel(pending)
        k = pending(q);
        R = regions(k);
        sc = 5; if isfield(R,'scale') && ~isempty(R.scale), sc = R.scale; end
        rep = pickFileResult(filesOut, files{q});
        if isempty(rep)
            results(k).note = '该区域没有返回结果'; continue;
        end
        results(k).items = flattenItems(rep, sc);
        results(k).engine = j.engine;
        if opts.useCache
            r0 = results(k); r0.cached = false;
            ocrCache('put', ocrCacheKey(R.I, cacheOpts(sc)), r0);
        end
    end
    fprintf('  [ocrBatch] 完成，用时 %.1f s\n', toc(t0));
end

%
function o = cacheOpts(sc)
    o = struct('scale',sc, 'variants',false, 'pass2',false, 'minCharH',4);
end

%
function [G, scale] = prepForOcr(I, scale, doBin, maxDim)
%PREPFOROCR  放大 + 可选二值化（纯 MATLAB）
    G0 = toGray(I);
    [H0, W0] = size(G0);
    if scale <= 0, scale = 5; end
    scale = max(1, min(scale, maxDim / max(H0, W0)));
    G = G0;
    if scale > 1.02
        G = imresize(G0, scale, 'bicubic');
    else
        scale = 1;
    end
    if doBin
        h = histcounts(G(:), 0:256);
        [~, bgIdx] = max(h);
        G = uint8(255 * (G >= max(0, (bgIdx-1) - 60)));
    else
        G = uint8(G);
    end
end

%
function rep = pickFileResult(filesOut, wantPath)
%PICKFILERESULT  按路径匹配本次批处理返回的结果
    rep = [];
    if isempty(filesOut), return; end
    [~, want] = fileparts(wantPath);
    for k = 1:numel(filesOut)
        if isfield(filesOut(k),'path') && ~isempty(filesOut(k).path)
            [~, got] = fileparts(char(filesOut(k).path));
            if strcmpi(got, want), rep = filesOut(k); return; end
        end
    end
    rep = filesOut(1);
end

%
function j = runWindowsOcrBatch(files)
%RUNWINDOWSOCRBATCH  一次 PowerShell 调用识别多个文件
    j = [];
    here = fileparts(mfilename('fullpath'));
    bridgePath = fullfile(here, 'ocr_bridge.ps1');
    if ~exist(bridgePath, 'file'), return; end
    exe = findPowerShell();
    if isempty(exe), return; end

    parts = cell(1, numel(files));
    for k = 1:numel(files)
        parts{k} = sprintf('''%s''', strrep(files{k}, '''', ''''''));
    end
    cmdText = sprintf(['$ErrorActionPreference=''Stop'';' ...
                       '$OcrPreferredLang=''en-US'';' ...
                       '$OcrImagePaths=@(%s);' ...
                       '$src=Get-Content -LiteralPath ''%s'' -Raw;' ...
                       '$sb=[scriptblock]::Create($src);& $sb'], ...
                       strjoin(parts, ','), bridgePath);
    b64 = matlab.net.base64encode(unicode2native(cmdText, 'UTF-16LE'));

    [st, out] = system(sprintf('"%s" -NoProfile -NonInteractive -EncodedCommand %s', exe, b64));
    if st ~= 0, return; end
    j = parseJsonBlock(char(out));
    if ~isempty(j) && ~isfield(j,'engine'), j.engine = 'windows-ocr'; end
end

%
function j = runTesseractBatch(files) %#ok<INUSD>
%RUNTESSERACTBATCH  未安装 tesseract 时返回空，保持接口一致
    j = [];
end


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


function rmTemp(d)
    try, rmdir(d, 's'); catch, end
end
