function items = ocrLineByLine(I, band, opts)
%OCRLINEBYLINE  把一块区域先切成"文字行"，再逐行放大 OCR。
%
%   为什么需要：整块区域一次性 OCR 时，引擎会按自己的版面分析切块，
%   图例里"样本 + 文字"混在一起时经常只认到半行。而把每一行文字单独
%   裁出来、高倍放大再识别，准确率高得多 —— 相当于人手一个个去看。
%
%   用法: items = ocrLineByLine(I, band, opts)
%     I    : 整幅图像
%     band : [x0 y0 x1 y1] 要处理的大致区域（可给整幅图）
%     opts.minBlobH / maxBlobH  文字行高度范围（原图像素）
%     opts.scale                每行再放大的倍数
%
%   返回 items 结构体数组（text/x/y/w/h，原始图像坐标）。

    if nargin < 3, opts = struct(); end
    if ~isfield(opts,'minBlobH'), opts.minBlobH = 8;   end
    if ~isfield(opts,'maxBlobH'), opts.maxBlobH = 60;  end
    if ~isfield(opts,'minBlobW'), opts.minBlobW = 40;  end
    if ~isfield(opts,'scale'),    opts.scale = 4;      end

    items = struct('text', {}, 'x', {}, 'y', {}, 'w', {}, 'h', {});
    G = toGrayLocal(I);
    x0 = max(1, band(1)); y0 = max(1, band(2));
    x1 = min(size(G,2), band(3)); y1 = min(size(G,1), band(4));
    if x1 <= x0 || y1 <= y0, return; end
    sub = G(y0:y1, x0:x1);      % sub(r,c) 对应整图 (y0+r-1, x0+c-1)

    % ---- 文字像素掩膜 ----
    h = histcounts(sub(:), 0:256);
    [~, bgIdx] = max(h);
    ink = sub < (bgIdx - 1) - 60;
    if ~any(ink(:))
        items = [];
        return;
    end

    % 水平膨胀，把同一行里相邻的词连起来。
    % 核宽必须自适应：字间距随字号缩放，固定核宽在"刻度数字 + 标题"挨得近时
    % 会把两行粘成一块，块高超过上限就被整块丢掉（这是之前轴标题读不到的根因）。
    rowInk = sum(ink, 2);
    nz = rowInk(rowInk > 0);
    if isempty(nz)
        items = []; return;
    end
    lineH = max(8, median(nz)/max(1,median(sum(ink,1))));   % 粗略的字高估计
    kernW = max(9, 2*round(lineH));                          % 约 2 个字宽
    kernW = min(kernW, 40);
    thick = conv2(double(ink), ones(1, kernW), 'same') > 0;
    % 竖直方向只做很小的连接，避免把上下两行并起来
    thick = conv2(double(thick), ones(3,1), 'same') > 0;

    [boxes, ~] = blobs(thick);
    if isempty(boxes), return; end

    % 尺寸过滤：只保留像"一行文字"的块
    bw = boxes(:,3) - boxes(:,1) + 1;
    bh = boxes(:,4) - boxes(:,2) + 1;
    keep = bh >= opts.minBlobH & bh <= opts.maxBlobH & bw >= opts.minBlobW;
    boxes = boxes(keep,:);
    if isempty(boxes), return; end

    % ---- 性能护栏：每行都要起一个 PowerShell 进程（约 0.3~0.5 s）----
    % 块太多时必须截断，否则一步就要等十几秒。
    % 按"面积优先"排序：真正的文字行通常比碎渣更长更实。
    maxLines = 14;
    if isfield(opts,'maxLines'), maxLines = opts.maxLines; end
    if size(boxes,1) > maxLines
        area = bw(keep) .* bh(keep);
        [~, o] = sort(area, 'descend');
        boxes = boxes(o(1:maxLines), :);
    end

    % 每行单独裁剪 + 放大 + OCR
    for k = 1:size(boxes,1)
        padx = 6; pady = 3;
        a = max(1, boxes(k,1)-padx); b = max(1, boxes(k,2)-pady);
        c = min(size(sub,2), boxes(k,3)+padx); d = min(size(sub,1), boxes(k,4)+pady);
        crop = I(y0+b-1 : y0+d-1, x0+a-1 : x0+c-1, :);
        r = ocrBridge(crop, struct('scale', opts.scale, 'pass2', false, ...
                                   'variants', false, 'minCharH', 4));
        for m = 1:numel(r.items)
            it = r.items(m);
            % 裁块的左上角在整图的坐标：x0+a-1, y0+b-1
            it.x = it.x + x0 + a - 2;
            it.y = it.y + y0 + b - 2;
            items(end+1) = it; %#ok<AGROW>
        end
    end
end

% =====================================================================
function [boxes, cols] = blobs(mask)
%BLOBS  连通域包围盒（8 邻域，游程 + 并查集）。cols 未用，保持接口一致。
    [H, ~] = size(mask);
    boxes = zeros(0,4);
    if ~any(mask(:)), cols = zeros(0,3); return; end

    parent = []; nextLabel = 0;
    allS = []; allE = []; allR = []; allL = [];
    prevRuns = zeros(0,2); prevLab = zeros(0,1);

    for r = 1:H
        v = mask(r,:);
        dd = diff([false, v, false]);
        ss = find(dd == 1); ee = find(dd == -1) - 1;
        cur = [ss(:), ee(:)];
        curLab = zeros(size(cur,1),1);
        for j = 1:size(cur,1)
            hit = [];
            for k = 1:size(prevRuns,1)
                if cur(j,2) >= prevRuns(k,1)-1 && cur(j,1) <= prevRuns(k,2)+1
                    hit(end+1) = prevLab(k); %#ok<AGROW>
                end
            end
            if isempty(hit)
                nextLabel = nextLabel + 1;
                parent(nextLabel) = nextLabel; %#ok<AGROW>
                curLab(j) = nextLabel;
            else
                curLab(j) = hit(1);
                for k = 2:numel(hit)
                    parent = unionL(parent, hit(1), hit(k));
                end
            end
        end
        prevRuns = cur; prevLab = curLab;
        if ~isempty(cur)
            allS = [allS; cur(:,1)]; allE = [allE; cur(:,2)]; %#ok<AGROW>
            allR = [allR; repmat(r, size(cur,1), 1)]; %#ok<AGROW>
            allL = [allL; curLab]; %#ok<AGROW>
        end
    end
    for k = 1:numel(allL), allL(k) = rootL(parent, allL(k)); end
    uL = unique(allL);
    boxes = zeros(numel(uL), 4);
    for k = 1:numel(uL)
        m = (allL == uL(k));
        boxes(k,:) = [min(allS(m)), min(allR(m)), max(allE(m)), max(allR(m))];
    end
    cols = zeros(0,3);
end

function r = rootL(parent, x)
    r = x;
    while parent(r) ~= r, r = parent(r); end
end

function parent = unionL(parent, a, b)
    ra = rootL(parent,a); rb = rootL(parent,b);
    if ra ~= rb, parent(max(ra,rb)) = min(ra,rb); end
end

function G = toGrayLocal(I)
    if ismatrix(I) && size(I,3) == 1
        G = double(I);
    else
        G = 0.299*double(I(:,:,1)) + 0.587*double(I(:,:,2)) + 0.114*double(I(:,:,3));
    end
end
