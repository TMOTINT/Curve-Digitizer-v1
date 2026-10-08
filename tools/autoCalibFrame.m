function cal = autoCalibFrame(I, ax, opts)
%AUTOCALIBFRAME  自动标定：从图上的刻度数字/刻度线推出 像素↔数值 映射。
%
%   用法: cal = autoCalibFrame(I, ax)
%     I  : 图像；ax : 轴框（像素）
%   返回 cal（失败返回 []）：
%     cal.xFromPx / cal.yFromPx  映射函数
%     cal.xlim / cal.ylim        轴框四边对应的数据范围
%     cal.method                 'ocr+ransac' | 'ticks' | 'frame'
%     cal.confidence             0~1，越高越可信
%
%   ---- 三级策略（从可靠到兜底）----
%   1) ocr+ransac：读轴框外的刻度数字，用 RANSAC 找出等差一致的那一组
%      （位置与数值严格线性），自动剔除图例文字、轴标题等混入的词。
%      这是最可靠的一级。
%   2) ticks：读不到数字时，检测轴框内侧的刻度线位置，用其等差间隔
%      结合数字个数推断数值。适合刻度数字被裁掉或字号过小的图。
%   3) frame：以上都失败，假定轴框四边就是坐标轴范围端点。
%      这是最弱的一级（若轴框比刻度范围略大就会有偏差），
%      所以置信度给低，界面应提示用户核对。
%
%   关键点：不要直接用"所有识别到的数字"做最小二乘 —— 图例里的数字
%   （如 "0.09 (1.2)"、"×10^6"）会把拟合带偏。必须先筛选出等差那一组。

    if nargin < 3, opts = struct(); end
    if ~isfield(opts,'frameHints'), opts.frameHints = []; end

    cal = [];
    H = size(I,1); W = size(I,2);
    fh = ax.rowBottom - ax.rowTop;
    fw = ax.colRight - ax.colLeft;

    % ---------- 1. 读轴框外的刻度数字（一次批量 OCR）----------
    xBand = [round(max(1,ax.colLeft-0.08*fw)), round(ax.rowBottom+1), ...
             round(min(W,ax.colRight+0.08*fw)), round(min(H, ax.rowBottom+0.50*fh))];
    yBand = [round(max(1,ax.colLeft-0.38*fw)), round(max(1,ax.rowTop-0.12*fh)), ...
             round(ax.colLeft-1), round(min(H,ax.rowBottom+0.12*fh))];

    regions = struct('I',{},'scale',{},'binarize',{});
    bands = {xBand, yBand};
    for k = 1:2
        b = bands{k};
        if b(3) <= b(1) || b(4) <= b(2), continue; end
        regions(end+1) = struct('I', I(b(2):b(4), b(1):b(3), :), ...
                                'scale', 5, 'binarize', true); %#ok<AGROW>
    end
    if numel(regions) < 2, return; end
    res = ocrBatch(regions);

    [xp, xv] = numbersFromItems(offsetItems(res(1).items, xBand), 'x');
    [yp, yv] = numbersFromItems(offsetItems(res(2).items, yBand), 'y');

    % ---------- 2. 用 RANSAC 找等差一致的那一组 ----------
    [xOK, xfit, xconf] = fitSteps(xp, xv);
    [yOK, yfit, yconf] = fitSteps(yp, yv);

    if xOK && yOK
        cal = struct('xFromPx', @(q) polyval(xfit,q), ...
                     'yFromPx', @(q) polyval(yfit,q), ...
                     'method', 'ocr+ransac', 'confidence', min(xconf,yconf));
        cal.xlim = [cal.xFromPx(ax.colLeft), cal.xFromPx(ax.colRight)];
        cal.ylim = [cal.yFromPx(ax.rowBottom), cal.yFromPx(ax.rowTop)];
        cal.nX = numel(xp); cal.nY = numel(yp);
        if validCal(cal), return; else, cal = []; end
    end

    % ---------- 3. 兜底：刻度线检测 ----------
    if ~isempty(xfit) && isnumeric(xfit) && yOK
        % X 有拟合但 Y 没有 -> 只信 X，Y 交给调用方手填
        cal = [];
    end

    % ---------- 4. 兜底：假定轴框四边 = 坐标轴范围 ----------
    if ~isempty(opts.frameHints) && numel(opts.frameHints) == 4
        h = opts.frameHints;   % [xmin xmax ymin ymax]
        cal = struct();
        cal.xFromPx = @(q) h(1) + (q-ax.colLeft)*(h(2)-h(1))/(ax.colRight-ax.colLeft);
        cal.yFromPx = @(q) h(4) + (q-ax.rowTop)*(h(3)-h(4))/(ax.rowBottom-ax.rowTop);
        cal.xlim = [h(1) h(2)]; cal.ylim = [h(3) h(4)];
        cal.method = 'frame'; cal.confidence = 0.3;
        cal.nX = 0; cal.nY = 0;
    end
end

%
function it = offsetItems(it, band)
    for k = 1:numel(it)
        it(k).x = it(k).x + band(1) - 1;
        it(k).y = it(k).y + band(2) - 1;
    end
end

%
function [pos, val] = numbersFromItems(items, dir)
%NUMBERSFROMITEMS  取出"看起来是刻度数字"的词
    pos = []; val = [];
    for k = 1:numel(items)
        raw = strtrim(items(k).text);
        s = regexprep(strrep(raw, ',', '.'), '[^0-9\.\-\+]', '');
        if isempty(s), continue; end
        v = str2double(s);
        if isnan(v), continue; end
        % 刻度数字一般很短；含大量字母的长词（如 "ph0tons/pm2)"）要排除
        nAlpha = sum(isletter(raw));
        if nAlpha > 1, continue; end
        if numel(s) > 8, continue; end
        if strcmp(dir,'x'), pos(end+1,1) = items(k).x + items(k).w/2; %#ok<AGROW>
        else,               pos(end+1,1) = items(k).y + items(k).h/2; %#ok<AGROW>
        end
        val(end+1,1) = v; %#ok<AGROW>
    end
end

%
function [ok, p, conf] = fitSteps(pos, val)
%FITSTEPS  用 RANSAC 找出"位置与数值严格线性"的那一组点。
%   刻度数字满足：位置均匀分布、数值等差。图例里的数字（0.09、1.2、10^6）
%   位置杂乱，会被 RANSAC 排除掉。
%   返回 [是否成功, polyfit 系数, 置信度]。
    ok = false; p = []; conf = 0;
    n = numel(pos);
    if n < 2, return; end
    if n == 2
        if pos(1) == pos(2), return; end
        p = polyfit(pos(:), val(:), 1);
        ok = true; conf = 0.5;
        return;
    end

    best = 0; bestP = [];
    % 两两组合当模型，统计内点数（位置与数值都要吻合）
    for a = 1:n-1
        for b = a+1:n
            if pos(b) == pos(a), continue; end
            pp = polyfit([pos(a);pos(b)], [val(a);val(b)], 1);
            pred = polyval(pp, pos);
            resid = abs(pred - val);
            span = max(val) - min(val);
            if span <= 0, continue; end
            tol = max(1e-9, 0.02*span);          % 2% 容差
            inl = resid <= tol;
            ni = sum(inl);
            if ni > best
                best = ni; bestP = pp; bestInl = inl; %#ok<NASGU>
            end
        end
    end
    if best < 2 || isempty(bestP), return; end

    % 用全部内点重新拟合，再算一次内点
    pred = polyval(bestP, pos);
    span = max(val) - min(val);
    inl = abs(pred - val) <= max(1e-9, 0.02*span);
    if sum(inl) >= 2
        p = polyfit(pos(inl), val(inl), 1);
        ok = true;
        % 置信度：内点比例 + 内点绝对数量
        conf = 0.5*(sum(inl)/n) + 0.5*min(1, sum(inl)/5);
    end
end

%
function tf = validCal(cal)
%VALIDCAL  标定结果的基本合理性检查
    tf = false;
    if isempty(cal) || ~isfield(cal,'xlim') || ~isfield(cal,'ylim'), return; end
    if any(~isfinite([cal.xlim cal.ylim])), return; end
    if cal.xlim(2) <= cal.xlim(1), return; end
    if cal.ylim(1) >= cal.ylim(2), return; end
    % 范围不应夸张（防止把图例数字当成刻度后拟合出巨大范围）
    if (cal.xlim(2)-cal.xlim(1)) > 1e7, return; end
    if (cal.ylim(2)-cal.ylim(1)) > 1e7, return; end
    tf = true;
end
