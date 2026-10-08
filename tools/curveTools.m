function varargout = curveTools(op, varargin)
%CURVETOOLS  论文曲线数字化：轴框识别 / 刻度标定 / 曲线追踪 / 导出
%
%   本文件是"函数库"，不直接运行；由界面和算法辅助函数调用。
%
%   本文件只用 MATLAB 基础功能，不依赖任何工具箱（已在 R2024a 上验证）。

switch lower(op)
    case 'detectaxes',  [varargout{1:nargout}] = detectAxes(varargin{:});
    case 'calibrate',   [varargout{1:nargout}] = calibrate(varargin{:});
    case 'snapseed',    [varargout{1:nargout}] = snapSeedToCurve(varargin{:});
    case 'showimg',     showImg(varargin{:});
    case 'trace',       [varargout{1:nargout}] = traceCurve(varargin{:});
    case 'reduce',      [varargout{1:nargout}] = reduceCurve(varargin{:});    case 'export',      [varargout{1:nargout}] = exportCurve(varargin{:});
    case 'overlay',     [varargout{1:nargout}] = overlayCheck(varargin{:});
    otherwise, error('curveTools: 未知操作 "%s"', op);
end
end

%
function ax = detectAxes(I)
%DETECTAXES  自动找出坐标轴矩形框（实线判据 + 角点连通校验）。
%
%   ================== 为什么重写 ==================
%   老版本判据是"投影值 >= 0.45×最大投影"，分不出实线和虚线 ——
%   实测 Fig.2E 里 y=0 那条水平虚线（横跨全宽的零线）投影值很高，
%   被当成了轴框的横轴，于是标定基准整条错位（算出来 1 px = 100 nm）。
%
%   新判据抓的是"实线"的本质：沿自身方向有很长的连续段。
%     · 实线轴框：一条从这头连到那头的连续线（最长连续段 ≈ 全长）
%     · 虚线/点线：最长连续段只有几像素（虽然总像素很多）
%   实测同一张图上：横轴行 411-414 的最长连续段 = 82% 宽度；
%   y=0 虚线行 333-336 的最长连续段只有 5% 宽度 —— 一判就分开。
%
%   返回 ax = struct('rowTop','rowBottom','colLeft','colRight')（图像像素坐标，1 起）

    if size(I,3) >= 3
        G = double(I(:,:,1))*0.299 + double(I(:,:,2))*0.587 + double(I(:,:,3))*0.114;
    else
        G = double(I);
    end
    [H, W] = size(G);

    % ---- 自适应阈值：取直方图峰值（背景）往左推 ----
    hist = histcounts(G(:), 0:256);
    [~, bgIdx] = max(hist);
    bg = bgIdx - 1;
    if bg < 40
        G = 255 - G;                       % 深底浅线：反向
        hist = histcounts(G(:), 0:256);
        [~, bgIdx] = max(hist);
        bg = bgIdx - 1;
    end
    thr = max(0, bg - 45);
    ink = G < thr;

    % ---- 逐行/逐列量"最长连续段"占比 ----
    rowFrac = zeros(H,1); colFrac = zeros(W,1);
    for r = 1:H, rowFrac(r) = longestRunFrac(ink(r,:)); end
    for c = 1:W, colFrac(c) = longestRunFrac(ink(:,c)); end

    % ---- 候选实线：连续段占比 >= solidFrac ----
    solidFrac = 0.60;
    rCand = find(rowFrac >= solidFrac);
    cCand = find(colFrac >= solidFrac);
    if getDebug()
        fprintf('  [dbg] thr=%d  H=%d W=%d  max(rowFrac)=%.3f max(colFrac)=%.3f  rCand=%d cCand=%d\n', ...
            thr, H, W, max(rowFrac), max(colFrac), numel(rCand), numel(cCand));
    end
    if numel(rCand) < 2 || numel(cCand) < 2
        % 放宽一档再试（有些图轴框线被曲线压出小缺口）
        solidFrac = 0.45;
        rCand = find(rowFrac >= solidFrac);
        cCand = find(colFrac >= solidFrac);
    end
    if isempty(rCand) || isempty(cCand)
        warning('detectAxes: 没找到实线框线（横 %d 条、竖 %d 条），回退为整幅图。', ...
                numel(rCand), numel(cCand));
        ax = struct('rowTop', 1, 'rowBottom', H, 'colLeft', 1, 'colRight', W);
        return;
    end

    % ---- 把相邻的行/列并成一条线 ----
    rGrp = groupConsecutiveWeighted(rCand, rowFrac(rCand));
    cGrp = groupConsecutiveWeighted(cCand, colFrac(cCand));
    rCent = round(cellfun(@(g) g(1), rGrp));
    rStr  = cellfun(@(g) g(2), rGrp);
    cCent = round(cellfun(@(g) g(1), cGrp));
    cStr  = cellfun(@(g) g(2), cGrp);

    % ---- 支持三种常见框型 ----
    %   ① 四条实线闭合的矩形（多数论文图）
    %   ② "半开口"：只有 左轴 + 右轴 + 横轴，没有上边框
    %      实测 Fig.2E 就是这种 —— 任何阈值下都找不到顶部横线，
    %      老版本要求"两条横线"于是拼不出框，直接回退成整幅图。
    %   ③ "L 形"：只有 左轴 + 横轴（matplotlib 默认的 2-spine 风格）
    % 三类一起打分，取最优。
    bestScore = -inf; ax = [];
    for a = 1:numel(rCent)
        for b = a+1:numel(rCent)
            % ---- ① 闭合矩形 ----
            for c = 1:numel(cCent)
                for d = c+1:numel(cCent)
                    cand = struct('rowTop', rCent(a), 'rowBottom', rCent(b), ...
                                  'colLeft', cCent(c), 'colRight', cCent(d));
                    [ok, sc] = scoreFrame(ink, cand, H, W, [rStr(a) rStr(b) cStr(c) cStr(d)]);
                    if ok && sc > bestScore, bestScore = sc; ax = cand; end
                end
            end
        end
    end
    % ---- ② 半开口：横线 + 两条竖线，上边界取竖线的顶端 ----
    %   注意：上边界是"合成"出来的（不是一条实线），所以强度分记 0 ——
    %   否则它靠竖线强度加成会盖过真正的闭合矩形（实测把 3A 从 0 偏到 1）。
    for a = 1:numel(rCent)
        % 先看这条横线上有没有"够长"的竖线顶端可用
        anyTall = false;
        for c = 1:numel(cCent)
            rT = topOfSpine(ink, cCent(c), rCent(a));
            if isfinite(rT) && (rCent(a) - rT) >= 0.20*H, anyTall = true; break; end
        end
        for c = 1:numel(cCent)
            for d = c+1:numel(cCent)
                rTop = topOfSpine(ink, cCent(c), rCent(a));
                if isfinite(rTop) && (rCent(a) - rTop) >= 0.20*H
                    cand = struct('rowTop', rTop, 'rowBottom', rCent(a), ...
                                  'colLeft', cCent(c), 'colRight', cCent(d));
                    [ok, sc] = scoreFrame(ink, cand, H, W, [0 rStr(a) cStr(c) cStr(d)]);
                    if ok && sc > bestScore, bestScore = sc; ax = cand; end
                elseif ~anyTall
                    % 退化情形：竖线一直连到图像顶边（上边框被裁掉了）。
                    %   只有在找不到任何合格竖线顶端时才用这个兜底，
                    %   否则会把本来正确的框拉成 top=1（实测在 3D 上踩过）。
                    cand = struct('rowTop', 1, 'rowBottom', rCent(a), ...
                                  'colLeft', cCent(c), 'colRight', cCent(d));
                    [ok, sc] = scoreFrame(ink, cand, H, W, [0 rStr(a)*0.5 cStr(c) cStr(d)]);
                    if ok && sc > bestScore
                        bestScore = sc; ax = cand;
                        if (rCent(a) - 1) < 0.20*H, ax.lowConfTop = true; end
                    end
                end
            end
        end
    end
    % ---- ③ L 形：横线 + 左竖线，右/上边界取线的末端（同样是合成边）----
    for a = 1:numel(rCent)
        for c = 1:numel(cCent)
            rTop = topOfSpine(ink, cCent(c), rCent(a));
            cRight = rightOfSpine(ink, rCent(a), cCent(c));
            if ~isfinite(rTop) || ~isfinite(cRight) || cRight - cCent(c) < 0.2*W
                continue;
            end
            cand = struct('rowTop', rTop, 'rowBottom', rCent(a), ...
                          'colLeft', cCent(c), 'colRight', cRight);
            [ok, sc] = scoreFrame(ink, cand, H, W, [0 rStr(a) cStr(c) 0]);
            if ok && sc > bestScore, bestScore = sc; ax = cand; end
        end
    end

    if isempty(ax) || ~isfinite(bestScore)
        warning('detectAxes: 候选线里拼不出像样的矩形框，回退为整幅图。');
        ax = struct('rowTop', 1, 'rowBottom', H, 'colLeft', 1, 'colRight', W);
        return;
    end

    if (ax.rowBottom - ax.rowTop) < 0.08*H || (ax.colRight - ax.colLeft) < 0.08*W
        warning('detectAxes: 检出的轴框偏小（%dx%d px），请目视确认。', ...
                round(ax.colRight-ax.colLeft), round(ax.rowBottom-ax.rowTop));
    end

    % 出口微调：把阈值暗带均值纠到"轴脊中心"（亚像素）。失败则原样返回。
    try
        axFix = refine_frame(I, ax);
        if isfinite(axFix.rowTop) && (axFix.rowBottom-axFix.rowTop) > 0.5*(ax.rowBottom-ax.rowTop)
            ax = axFix;
        end
    catch
    end
    fprintf(['  [detectAxes] 轴框(亚像素): top=%.2f bottom=%.2f left=%.2f right=%.2f  (%.0fx%.0f px)' ...
             '  实线阈值 %.2f%s\n'], ...
        ax.rowTop, ax.rowBottom, ax.colLeft, ax.colRight, ...
        ax.colRight-ax.colLeft, ax.rowBottom-ax.rowTop, solidFrac, ...
        ternStr(isfield(ax,'lowConfTop') && ax.lowConfTop, ...
                '  ⚠ 上边界按图像顶边取值，请在预览里核对', ''));
end

%
function s = ternStr(c, a, b)
    if c, s = a; else, s = b; end
end

%
function [ok, score] = scoreFrame(ink, cand, H, W, strengths)
%SCOREFRAME  给一个候选轴框打分：够大、长宽比合理、边线确是实线
    ok = false; score = -inf;
    h = cand.rowBottom - cand.rowTop;
    w = cand.colRight - cand.colLeft;
    if h < 0.06*H || w < 0.06*W, return; end
    ar = w / h;
    if ar > 15 || ar < 0.12, return; end
    % 左竖线与横轴必须在左下角真的相交（防止把页眉条和竖边拼在一起）
    if ~cornerHasInk(ink, cand.rowBottom, cand.colLeft, 6), return; end
    % 左竖线要到得了上边界附近（半开口/L 形时上边界就是它的顶端）
    if ~edgeReaches(ink, cand.colLeft, 'v', cand.rowTop, cand.rowBottom, 0.6), return; end
    score = w*h/(W*H) + 0.10*sum(strengths(:));
    ok = true;
end

%
function rTop = topOfSpine(ink, c, rBottom)
%TOPOFSPINE  竖线（y 轴）的顶端行 —— 半开口框的上边界就是它
%   只接受"从横轴一路连上来的那一段"的起点，且必须离横轴足够远，
%   否则会把竖线上一小段杂点当成框的顶端（实测出现过 top=1 的荒谬结果）。
    rTop = NaN;
    [H, W] = size(ink);
    c = max(1, min(W, c));
    rBottom = max(1, min(H, rBottom));
    v = ink(1:rBottom, c);
    d = diff([false; v; false]);
    s0 = find(d==1); e0 = find(d==-1)-1;
    if isempty(s0), return; end
    keep = find(e0 >= rBottom - 3);        % 这一段必须连到横轴
    if isempty(keep), return; end
    [~, bi] = max(e0(keep) - s0(keep));
    cand = s0(keep(bi));
    if rBottom - cand < 0.10*H, return; end   % 太短：不像轴框的竖边
    rTop = cand;
end

%
function cRight = rightOfSpine(ink, r, cLeft)
%RIGHTOFSPINE  横线（x 轴）的右端列 —— L 形框的右边界就是它
    cRight = NaN;
    r = max(1, min(size(ink,1), r));
    cLeft = max(1, min(size(ink,2), cLeft));
    v = ink(r, cLeft:end);
    d = diff([false, v, false]);
    s0 = find(d==1); e0 = find(d==-1)-1;
    if isempty(s0), return; end
    keep = find(s0 <= 4);
    if isempty(keep), return; end
    [~, bi] = max(e0(keep) - s0(keep));
    cRight = cLeft + e0(keep(bi)) - 1;
end

%
function tf = cornerHasInk(ink, r, c, rad)
%CORNERHASINK  角点附近有没有墨迹（两条框线是否真的相交）
    r0 = max(1, r-rad); r1 = min(size(ink,1), r+rad);
    c0 = max(1, c-rad); c1 = min(size(ink,2), c+rad);
    tf = any(any(ink(r0:r1, c0:c1)));
end

%
function tf = getDebug()
%GETDEBUG  诊断开关：设环境变量 CURVETOOLS_DEBUG=1 打开
    tf = strcmp(getenv('CURVETOOLS_DEBUG'), '1');
end

%
function f = longestRunFrac(v)
%LONGESTRUNFRAC  一条线里"最长连续段"占该方向长度的比例
%   实线接近 1，虚线只有几个像素 —— 这是区分两者的关键量。
    v = logical(v(:)');
    if isempty(v), f = 0; return; end
    d = diff([false, v, false]);
    s0 = find(d==1); e0 = find(d==-1)-1;
    if isempty(s0), f = 0; else, f = max(e0 - s0 + 1) / numel(v); end
end

%
function grp = groupConsecutiveWeighted(idx, w)
%GROUPCONSECUTIVEWEIGHTED  把相邻下标并成一组，返回 {加权中心, 组内最大权重}
    grp = {};
    if isempty(idx), return; end
    s = 1;
    for k = 2:(numel(idx)+1)
        if k > numel(idx) || idx(k) - idx(k-1) > 1
            seg = idx(s:k-1); ww = w(s:k-1);
            cen = sum(seg(:).*ww(:)) / max(eps, sum(ww));
            grp{end+1} = [cen, max(ww)]; %#ok<AGROW>
            s = k;
        end
    end
end

%
function tf = edgeReaches(ink, r, dir, lo, hi, frac)
%EDGEREACHES  这条边是否真的延伸到对边的角上（防止页眉线与竖边拼出假框）
    if strcmp(dir, 'h')
        rr = max(1, min(size(ink,1), r));
        seg = ink(rr, max(1,lo):min(size(ink,2),hi));
    else
        cc = max(1, min(size(ink,2), r));
        seg = ink(max(1,lo):min(size(ink,1),hi), cc)';
    end
    if isempty(seg), tf = false; return; end
    tf = longestRunFrac(seg) >= frac * 0.6;   % 允许抗锯齿造成的少量缺口
end

%
function centers = axisLines(proj, n)
%AXISLINES  从投影曲线里找出候选框线的中心位置。
%   判据：投影值 >= max(8, 0.45*最大值)，且至少占该方向长度的 25%。
%   后者用于排除只有几个黑点（文字笔画）的噪声行。
    if isempty(proj) || max(proj) <= 0, centers = []; return; end
    thr = max(8, 0.45*max(proj));
    minLen = round(0.25*n);
    idx = find(proj >= thr & proj >= minLen);
    if isempty(idx), centers = []; return; end
    g = groupConsecutive(idx);
    centers = arrayfun(@(k) mean(g{k}), 1:numel(g));
    centers = centers(:);
end

%
function tf = linesConnect(dark, r, dir, lo, hi, frac)
%LINESCONNECT  判断一条框线是否真的连到了它对边的角上。
%   dark : 二值图
%   r    : 该线的行(或列)号
%   dir  : 'h' 表示 r 是行号（水平线）；'v' 表示 r 是列号（垂直线）
%   lo,hi: 对边两条线的位置（水平线看左右边的列号，垂直线看上下的行号）
%   判据：这条线在 [lo,hi] 区间内的黑色像素跨度，要覆盖区间长度的 frac 以上。
    if strcmp(dir, 'h')
        span = find(dark(round(r), :));
    else
        span = find(dark(:, round(r)));
    end
    if isempty(span), tf = false; return; end
    a = max(min(span), lo); b = min(max(span), hi);
    cov = (b - a) / max(1, hi - lo);
    tf = cov >= frac;
end

%
function g = groupConsecutive(idx)
    if isempty(idx), g = {}; return; end
    brk = find(diff(idx) > 3);
    s = [idx(1); idx(brk+1)];
    e = [idx(brk); idx(end)];
    g = arrayfun(@(k) (s(k):e(k))', 1:numel(s), 'UniformOutput', false);
end

%
function cal = calibrate(I, ax, xKnown, yKnown)
%CALIBRATE  点选标定。
%   xKnown = [v1 v2] 点的两个已知 X 值（任意两个刻度都行，距离越远越好）
%   yKnown = [v1 v2] 点的两个已知 Y 值
%   会依次让你点 4 个点。放大的做法：先在图上滚轮/工具栏放大，再点，精度更高。

    f = figure('Name','标定：按提示点 4 个点', ...
               'NumberTitle','off', 'Color','w');
    showImg(I); hold on;

    % 先画上轴框，方便对照
    plot([ax.colLeft ax.colRight ax.colRight ax.colLeft ax.colLeft], ...
         [ax.rowTop ax.rowTop ax.rowBottom ax.rowBottom ax.rowTop], ...
         'c-', 'LineWidth', 1);

    pts = zeros(4,2);
    labels = { ...
        sprintf('点 X 轴刻度 "%g" 的位置', xKnown(1)), ...
        sprintf('点 X 轴刻度 "%g" 的位置', xKnown(2)), ...
        sprintf('点 Y 轴刻度 "%g" 的位置', yKnown(1)), ...
        sprintf('点 Y 轴刻度 "%g" 的位置', yKnown(2))};

    for k = 1:4
        title(labels{k}, 'FontSize', 13, 'Color', 'k');
        fprintf('  请点选：%s\n', labels{k});
        [px, py] = ginput(1);
        pts(k,:) = [px, py];
        plot(px, py, 'r+', 'MarkerSize', 14, 'LineWidth', 2);
        text(px, py, sprintf('  %s', labels{k}), 'Color','r', 'FontSize', 10);
        drawnow;
    end

    % 拟合（点 1-2 定 X 映射，点 3-4 定 Y 映射）
    cal.xFromPx = @(px) pts(1,1)*0 + linearMap(px, pts(1,1), xKnown(1), pts(2,1), xKnown(2));
    cal.yFromPx = @(py) linearMap(py, pts(3,2), yKnown(1), pts(4,2), yKnown(2));
    cal.pts = pts;
    cal.xKnown = xKnown;
    cal.yKnown = yKnown;

    % 顺带算出轴框四角对应的数据范围，便于核对
    cal.xlim = [cal.xFromPx(ax.colLeft), cal.xFromPx(ax.colRight)];
    cal.ylim = [cal.yFromPx(ax.rowBottom), cal.yFromPx(ax.rowTop)];

    fprintf('  [calibrate] X: %g -> px %.1f , %g -> px %.1f   (%.2f px/单位)\n', ...
        xKnown(1), pts(1,1), xKnown(2), pts(2,1), abs(pts(2,1)-pts(1,1))/abs(xKnown(2)-xKnown(1)));
    fprintf('  [calibrate] Y: %g -> px %.1f , %g -> px %.1f   (%.2f px/单位)\n', ...
        yKnown(1), pts(3,2), yKnown(2), pts(4,2), abs(pts(4,2)-pts(3,2))/abs(yKnown(2)-yKnown(1)));
    fprintf('  [calibrate] 轴框对应数据范围: X = [%.3f, %.3f], Y = [%.3f, %.3f]\n', ...
        cal.xlim(1), cal.xlim(2), cal.ylim(1), cal.ylim(2));
    fprintf('              若与图上刻度范围不符，说明点偏了，重跑并放大后再点。\n');

    close(f);
end

function v = linearMap(p, p1, v1, p2, v2)
    if p2 == p1, error('linearMap: 两个标定点像素位置重合'); end
    v = v1 + (p - p1) * (v2 - v1) / (p2 - p1);
end

%
function [res, info] = traceCurve(I, ax, cal, seedXY, cfg)
%TRACECURVE  从种子点出发沿曲线区域生长追踪。
%   seedXY = [x y] 你点的一个曲线上的点（图像像素坐标）
%   cfg.colorTol  颜色距离阈值（0-255 制），默认 60
%   cfg.radius    每步搜索半径，默认 6
%   cfg.mask      可选，预先算好的候选掩膜，用于忽略图例
%
%   返回 res.pathPx = [x y] 像素路径（N x 2），res.X / res.Y 为标定后的数据坐标。
%   归约成单值曲线请把 res.pathPx 交给 'reduce'（务必用像素列分列，
%   不要用数据坐标的 X 分列 —— 数据坐标取整会把整条曲线并成几个桶）。
%
%   原理：以种子颜色为目标，在候选掩膜内做"只走未访问像素"的贪婪生长，
%   每步优先向右（列 +1）前进，允许 ±rankStep 列的回退以处理陡峭段。
%   这样即使多条曲线同色，也只会沿你点的这一条走。

    if nargin < 5, cfg = struct(); end
    if ~isfield(cfg,'colorTol'),  cfg.colorTol = 60;   end
    if ~isfield(cfg,'radius'),    cfg.radius = 6;      end
    if ~isfield(cfg,'rankStep'),  cfg.rankStep = 2;    end
    if ~isfield(cfg,'maxIter'),   cfg.maxIter = 60*size(I,2); end

    D = double(I);
    [H, W, ~] = size(D);

    seedX = round(seedXY(1)); seedY = round(seedXY(2));
    if seedX < 1 || seedX > W || seedY < 1 || seedY > H
        error('traceCurve: 种子点超出图像范围');
    end
    seedCol = reshape(D(seedY, seedX, :), 1, 3);

    % --- 颜色掩膜 ---
    if isfield(cfg,'mask') && ~isempty(cfg.mask)
        cand = cfg.mask;
    else
        cand = colorMask(D, seedCol, cfg.colorTol);
    end
    % 收窄到轴框内，避免跑到图例/轴标签上
    box = false(H, W);
    box(round(ax.rowTop)+1:round(ax.rowBottom)-1, round(ax.colLeft)+1:round(ax.colRight)-1) = true;
    cand = cand & box;
    % 形态学收尾：补小洞、去毛刺（全部用基础 MATLAB，不依赖 Image Processing Toolbox）
    cand = cleanMask(cand);
    if ~cand(seedY, seedX)
        % 种子点本身被形态学去掉了 -> 就近吸附到一个候选像素
        [yy, xx] = find(cand);
        if isempty(yy), error('traceCurve: 掩膜为空，颜色阈值太小或种子点颜色不对'); end
        [~, k] = min((yy-seedY).^2 + (xx-seedX).^2);
        seedY = yy(k); seedX = xx(k);
        warning('traceCurve: 种子点吸附到最近候选像素 (%d,%d)', seedX, seedY);
    end

    % --- 贪婪生长 ---
    visited = false(H, W);
    cap = 4096;
    pathBuf = zeros(cap, 2);
    n = 0;
    curX = seedX; curY = seedY;
    R = cfg.radius;
    visited(curY, curX) = true;
    n = n + 1;
    pathBuf(n,:) = [curX, curY];

    dir = 1;        % 先往右走
    stall = 0;
    it = 0;
    MAXJUMP = 14;   % 允许的最大跳跃距离（px），用于跨过虚线段或标记符号
    while it < cfg.maxIter
        it = it + 1;

        % ---- 第一级：局部前进（优先 dir 方向）----
        best = [];
        c1 = curX - cfg.rankStep; c2 = curX + cfg.rankStep;
        rr = max(1, curY-R):min(H, curY+R);
        cc = max(1, c1):min(W, c2);
        sub = cand(rr, cc) & ~visited(rr, cc);
        if any(sub(:))
            [sy, sx] = find(sub);
            xs = cc(1) + sx - 1;
            ys = rr(1) + sy - 1;
            dx = xs - curX;
            dy = ys - curY;
            dist = dx.^2 + dy.^2;
            penalty = zeros(size(dist));
            penalty(dx*dir < 0) = 4;                    % 轻微惩罚倒退
            penalty(dx*dir == 0 & abs(dy) > 2) = 1;     % 纯竖直移动也稍作惩罚
            [~, k] = min(dist + penalty*10);
            best = [xs(k), ys(k)];
        end

        % ---- 第二级：局部断开，在 MAXJUMP 内跳跃续接 ----
        if isempty(best)
            r2 = max(1, curY-MAXJUMP):min(H, curY+MAXJUMP);
            c2a = max(1, curX-MAXJUMP):min(W, curX+MAXJUMP);
            sub2 = cand(r2, c2a) & ~visited(r2, c2a);
            if any(sub2(:))
                [sy2, sx2] = find(sub2);
                xs2 = c2a(1) + sx2 - 1;
                ys2 = r2(1) + sy2 - 1;
                d2 = (xs2-curX).^2 + (ys2-curY).^2;
                pen2 = zeros(size(d2));
                pen2((xs2-curX)*dir < 0) = 40;          % 强惩罚倒退
                [~, k2] = min(d2 + pen2);
                best = [xs2(k2), ys2(k2)];
            end
        end

        % ---- 两级都没找到：记一次停滞，连续太多次才收工 ----
        if isempty(best)
            stall = stall + 1;
            if stall > 400
                break;
            end
            continue;       % 不动 curX/curY，下一轮再试
        end

        if (best(1)-curX)^2 + (best(2)-curY)^2 > (cfg.rankStep^2 + R^2)
            stall = stall + 1;      % 这次是跳跃，不算顺畅前进
        else
            stall = 0;
        end

        visited(best(2), best(1)) = true;
        n = n + 1;
        if n > cap
            pathBuf = [pathBuf; zeros(cap, 2)]; %#ok<AGROW>
            cap = cap * 2;
        end
        pathBuf(n,:) = [best(1), best(2)];
        curX = best(1); curY = best(2);
    end
    path = pathBuf(1:n, :);

    if size(path,1) < 20
        warning('traceCurve: 只追踪到 %d 个点，可能种子点颜色不对或曲线断开', size(path,1));
    end

    X = cal.xFromPx(path(:,1));
    Y = cal.yFromPx(path(:,2));

    res.pathPx = path;
    res.X = X;
    res.Y = Y;
    res.seedColor = seedCol;
    res.mask = cand;                 % 供 reduce 取中心线用

    info.pathPx = path;
    info.path   = path;
    info.seedColor = seedCol;
    info.nPts   = size(path,1);
    info.nStall = stall;

    fprintf('  [traceCurve] 追踪到 %d 个点，覆盖 %d 个像素列，X 范围 [%.3f, %.3f]，Y 范围 [%.3f, %.3f]\n', ...
        info.nPts, numel(unique(path(:,1))), min(X), max(X), min(Y), max(Y));
end

%
function m = colorMask(D, c, tol)
    dr = D(:,:,1) - c(1);
    dg = D(:,:,2) - c(2);
    db = D(:,:,3) - c(3);
    m = (dr.^2 + dg.^2 + db.^2) <= tol^2;
end

%
function [pt, col, moved] = snapSeedToCurve(I, xy, maxR)
%SNAPSEEDTOCURVE  把用户点的种子点吸附到附近"确实是曲线"的像素上。
%
%   用途：用户很难点得正好落在 2~3 px 宽的线上。如果种子落在白色
%   背景上，按种子颜色建的掩膜会把整个背景都选进来，追踪立刻失效。
%
%   判据：像素要"明显不是背景"—— 即离白色的距离足够大（深色线）或
%   饱和度足够高（彩色线）。用局部阈值（邻域 99 分位）自适应，
%   所以深色线和浅色线都能处理。
%
%   返回吸附后的点 pt、该点颜色 col、以及是否发生了移动 moved。

    if nargin < 3 || isempty(maxR), maxR = 8; end
    D = double(I);
    [H, W, ~] = size(D);
    x0 = round(xy(1)); y0 = round(xy(2));
    r0 = max(1, y0-maxR):min(H, y0+maxR);
    c0 = max(1, x0-maxR):min(W, x0+maxR);

    dWhite = sqrt((D(:,:,1)-255).^2 + (D(:,:,2)-255).^2 + (D(:,:,3)-255).^2);
    mx = max(D, [], 3); mn = min(D, [], 3);
    sat = mx - mn;                       % 简易饱和度
    strength = max(dWhite, sat);         % 深色或高饱和都算"强"

    sub = strength(r0, c0);
    thr = prctile(sub(:), 99);           % 自适应阈值
    if thr < 40
        % 邻域内没有明显曲线像素：保持原点，不要瞎吸
        pt = [x0, y0]; col = reshape(D(y0,x0,:), 1, 3); moved = false;
        return;
    end
    cand = sub >= max(thr, 40);
    [sy, sx] = find(cand);
    ys = r0(1) + sy - 1; xs = c0(1) + sx - 1;
    dd = (xs - x0).^2 + (ys - y0).^2;
    [~, k] = min(dd);
    pt = [xs(k), ys(k)];
    col = reshape(D(pt(2), pt(1), :), 1, 3);
    moved = (pt(1) ~= x0) || (pt(2) ~= y0);
    if moved
        fprintf('  [snapSeed] 种子点 (%d,%d) -> (%d,%d)，颜色 [%d %d %d]\n', ...
            x0, y0, pt(1), pt(2), round(col));
    end
end

%
function showImg(I)
%SHOWIMG  显示图像（基础 MATLAB 实现，替代 imshow）
    image(I);
    axis image;
    axis off;
    set(gca, 'YDir', 'reverse');   % 与图像像素坐标一致：行号向下增大
end

%
function m = dilate1(m)
%DILATE1  3x3 二值膨胀（基础 MATLAB 实现，替代 imdilate）
    k = [1 1 1; 1 1 1; 1 1 1];
    m = conv2(double(m), k, 'same') > 0;
end

function m = cleanMask(m)
%CLEANMASK  轻量形态学收尾：先膨胀连接断点，再去掉孤立小连通块。
%   替代 imclose + bwareaopen，避免依赖 Image Processing Toolbox。
    m = dilate1(m);
    % 8 邻域计数；膨胀后曲线像素至少有 3 个邻居，孤立噪点只有 1~2 个
    n = conv2(double(m), ones(3), 'same') - double(m);
    m = m & (n >= 2);
    m = dilate1(m);     % 再膨胀一次，补回因上一步收缩掉的细线
end

%
function [X, Y, bi] = reduceCurve(pathPx, cal, how)
%REDUCECURVE  把逐像素路径归约成"单值曲线"：每个像素列只保留一个 Y。
%
%   必须传像素路径 pathPx（N x 2，来自 trace 的 res.pathPx），
%   而不是数据坐标 —— 数据坐标取整会把整条曲线并成几个桶。
%
%   how='fit'（默认，最准）：对每个像素列，只取与路径连通的那一段
%       候选掩膜像素，用它们的质心作为该列的 Y。"连通段"的判定是：从路径
%       中位行向上下扩展，遇到连续 >=3 行空白即停 —— 这样窗口不会跨到
%       同一列里的另一条曲线上（多条曲线重叠时这一点很关键）。
%       质心对线宽对称加粗不敏感、也没有方向偏差，比沿路径点拟合更准。
%       若该列没有掩膜（罕见），退化为对路径点做最小二乘拟合。
%   how='median' / 'mean'：直接对路径点取中位数/均值，最省事但有方向偏差。
%
%   可选的 bi 用于诊断。bi.overlap 报告多少列出现多值（曲线自交/与同色线重叠）。

    if nargin < 3 || isempty(how), how = 'fit'; end

    [~, order] = sort(pathPx(:,1));
    pathPx = pathPx(order, :);
    xp = pathPx(:,1);
    yp = pathPx(:,2);

    cols = round(xp);
    ucols = unique(cols);
    Xo = zeros(numel(ucols),1);
    Yo = zeros(numel(ucols),1);
    overlap = 0;

    % fit 模式需要的掩膜
    M = [];
    if strcmpi(how, 'fit') && isfield(cal, 'mask') && ~isempty(cal.mask)
        M = cal.mask;
    end
    H = size(M, 1);

    for k = 1:numel(ucols)
        m = (cols == ucols(k));
        xk = xp(m); yk = yp(m);
        Xo(k) = mean(xk);

        if numel(yk) > 1
            ys = sort(yk);
            span = max(ys) - min(ys);
            gaps = diff(ys);
            if span > 0 && max(gaps) > 0.5*span
                overlap = overlap + 1;   % 这一列 Y 分成多簇 -> 多值
            end
        end

        if strcmpi(how, 'median')
            Yo(k) = median(yk);
        elseif strcmpi(how, 'mean')
            Yo(k) = mean(yk);
        else
            got = false;
            c = ucols(k);
            if ~isempty(M) && c >= 1 && c <= size(M,2)
                % 只取"与路径连通的那一段"掩膜，避免窗口跨到别的曲线上。
                % 做法：从路径中位行向外扩，遇到连续 >=3 行空白就停。
                ctr = median(yk);
                up = floor(ctr); dn = ceil(ctr);
                gapU = 0; gapD = 0;
                while up > 1 && gapU < 3
                    up = up - 1;
                    if M(up, c), gapU = 0; else, gapU = gapU + 1; end
                end
                while dn < H && gapD < 3
                    dn = dn + 1;
                    if M(dn, c), gapD = 0; else, gapD = gapD + 1; end
                end
                rr = find(M(up:dn, c));
                if numel(rr) >= 2
                    Yo(k) = up - 1 + mean(rr);   % 该连通段的质心 = 中心线
                    got = true;
                end
            end
            if ~got
                if numel(yk) >= 3 && (max(xk) - min(xk)) > 0
                    p = polyfit(xk, yk, 1);
                    Yo(k) = polyval(p, Xo(k));
                else
                    Yo(k) = median(yk);
                end
            end
        end
    end

    % 像素 -> 数据坐标
    X = cal.xFromPx(Xo);
    Y = cal.yFromPx(Yo);
    bi.overlap = overlap;
    bi.pathReduced = [Xo, Yo];
    if overlap > 0
        fprintf('  [reduceCurve] 提示：%d 个像素列存在多值（曲线自交或与另一条线重叠）。\n', overlap);
    end
end

%
function out = exportCurve(name, X, Y, meta)
%EXPORTCURVE  导出 CSV + MAT，并附一带来源信息的 txt。
    if nargin < 4, meta = struct(); end
    out = struct();

    out.csv = sprintf('%s.csv', name);
    M = [X(:), Y(:)];
    writematrix(M, out.csv);
    out.mat = sprintf('%s.mat', name);
    save(out.mat, 'X', 'Y', 'meta');

    out.txt = sprintf('%s_provenance.txt', name);
    fid = fopen(out.txt, 'w');
    fprintf(fid, 'data file     : %s\n', out.csv);
    fprintf(fid, 'digitized at  : %s\n', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')));
    fprintf(fid, 'n points      : %d\n', numel(X));
    fprintf(fid, 'X range       : %.6g .. %.6g\n', min(X), max(X));
    fprintf(fid, 'Y range       : %.6g .. %.6g\n', min(Y), max(Y));
    fprintf(fid, 'source figure : %s\n', getfielddef(meta, 'source', '?'));
    fprintf(fid, 'source file   : %s\n', getfielddef(meta, 'file', '?'));
    fprintf(fid, 'axis range    : X [%s], Y [%s]\n', ...
        mat2str(getfielddef(meta,'xlim',[])), mat2str(getfielddef(meta,'ylim',[])));
    fprintf(fid, 'method        : pixel digitization of a 300-dpi raster figure\n');
    fprintf(fid, '                (color region-growing trace + tick calibration)\n');
    fprintf(fid, 'caveat        : reading error ~1-2 px; do not treat as原始数据\n');
    fclose(fid);

    fprintf('  [export] %s  (%d 点)\n', out.csv, numel(X));
end

function v = getfielddef(s, f, d)
    if isfield(s, f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end

%
function overlayCheck(I, ax, cal, curves)
%OVERLAYCHECK  验证：把数字化结果画回原图，并画出数据坐标下的结果。
%   curves 是 struct 数组，字段 name / X / Y / path(可选)

    figure('Name','验证：数字化结果 vs 原图', 'NumberTitle','off', ...
           'Color','w', 'Position',[80 60 1500 800]);

    subplot(1,2,1);
    showImg(I); hold on;
    plot([ax.colLeft ax.colRight ax.colRight ax.colLeft ax.colLeft], ...
         [ax.rowTop ax.rowTop ax.rowBottom ax.rowBottom ax.rowTop], 'c-', 'LineWidth', 1.2);
    cols = lines(numel(curves));
    for k = 1:numel(curves)
        if isfield(curves(k),'pathPx') && ~isempty(curves(k).pathPx)
            p = curves(k).pathPx;
            plot(p(:,1), p(:,2), '-', 'Color', cols(k,:), 'LineWidth', 1.4);
        end
    end
    title('叠回原图：彩色线应完全覆盖原曲线', 'FontSize', 12);

    subplot(1,2,2); hold on; grid on; box on;
    for k = 1:numel(curves)
        plot(curves(k).X, curves(k).Y, '-', 'Color', cols(k,:), 'LineWidth', 1.2);
    end
    xlim(cal.xlim); ylim(cal.ylim);
    xlabel('X (数据坐标)'); ylabel('Y (数据坐标)');
    title('提取出的数据', 'FontSize', 12);
    legend({curves.name}, 'Location','best', 'Interpreter','none');
    drawnow;
end
