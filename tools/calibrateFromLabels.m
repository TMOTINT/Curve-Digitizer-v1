function out = calibrateFromLabels(I, ax, opts)
%CALIBRATEFROMLABELS  用 OCR 读到的刻度数字拟合出坐标映射，并外推到轴框边界
%
%   ==================== 用途它 ====================
%   很多图的轴框比标注范围更大：实测 Fig.3A 的 y 轴只标到 500，
%   但轴框顶边对应约 575 nm —— 肉眼看不出这个最大值，靠猜就会标定错。
%
%   做法（比"取最大标注值当上界"可靠得多）：
%     1. OCR 读出每个刻度数字的文字 + 它的像素行/列中心
%     2. 对"数值 ~ 像素位置"做最小二乘直线拟合（多个刻度一起平均，
%        抗单个误读；残差还能直接当质量指标）
%     3. 把拟合直线外推到轴框的四条边，得到该框对应的真实数值范围
%
%   用法:
%     out = calibrateFromLabels(I, ax)                 % ax 为轴框结构体
%     out = calibrateFromLabels(I, ax, struct('scale',4))
%
%   返回:
%     out.ok         是否成功
%     out.cal        标定结构体（xFromPx/yFromPx/xlim/ylim/method）
%     out.xTicks/yTicks   读到的刻度值
%     out.xRows/yRows     刻度对应的像素位置
%     out.xRes/yRes       拟合残差 RMS（像素/单位），用于判断可靠度
%     out.note       说明文字
%
%   依赖 tools/ocrBatch.m（Windows 自带 OCR）。没有 OCR 时 out.ok=false。

    if nargin < 3, opts = struct(); end
    if ~isfield(opts,'scale'), opts.scale = 4; end
    if ~isfield(opts,'maxResid'), opts.maxResid = 1.5; end   % 残差超此值判为不可靠
    out = struct('ok',false,'cal',[],'xTicks',[],'yTicks',[], ...
                 'xRows',[],'yRows',[],'xRes',NaN,'yRes',NaN,'note','');

    if ~exist('ocrBatch','file')
        out.note = '找不到 ocrBatch（需要 tools/ocrBatch.m）'; return;
    end
    if size(I,3) == 1, I = repmat(I,1,1,3); end
    H = size(I,1); W = size(I,2);
    fw = ax.colRight - ax.colLeft;
    fh = ax.rowBottom - ax.rowTop;

    % ---- 两条标签带：X 在框下方，Y 在框左侧 ----
    % X 带要够高：刻度数字常常离框 10~30 px；带太矮会把数字下半截切掉，
    %   OCR 就一个字都读不出来（实测 30 px 高的带读到 0 项，加高后正常）。
    %   轴标题在更下面，靠 0.30 倍框高这个上限把它排除。
    xb = [max(1,round(ax.colLeft-0.06*fw)), min(H,round(ax.rowBottom+2)), ...
          min(W,round(ax.colRight+0.06*fw)), min(H,round(ax.rowBottom+0.30*fh))];
    yb = [max(1,round(ax.colLeft-0.30*fw)), max(1,round(ax.rowTop-0.05*fh)), ...
          max(2,round(ax.colLeft-2)),           min(H,round(ax.rowBottom+0.05*fh))];

    regs(1) = struct('I', I(xb(2):max(xb(2),xb(4)), xb(1):max(xb(1),xb(3)), :), ...
                     'scale', opts.scale, 'binarize', true);
    regs(2) = struct('I', I(yb(2):max(yb(2),yb(4)), yb(1):max(yb(1),yb(3)), :), ...
                     'scale', opts.scale, 'binarize', true);
    res = ocrBatch(regs, struct('useCache', false));

    % 坐标是区域坐标（ocrBatch 内部先裁了区域再识别），
    %   所以这里偏移一律给 0；再加一次偏移会把刻度位置整体挪走，
    %   导致归并错组（实测把 "200" 归成 "2000"）。
    [vx, px, tx] = itemsToTicks(res(1), 0, 0, 'x');
    [vy, py, ty] = itemsToTicks(res(2), 0, 0, 'y');

    if numel(vx) >= 2
        [cf, rms] = fitLine(px, vx);
        out.xTicks = vx; out.xRows = px; out.xRes = rms;
        xFromPx = @(q) cf(1)*q + cf(2);
        xlim = sort([xFromPx(ax.colLeft), xFromPx(ax.colRight)]);
        okX = rms <= opts.maxResid;
    else
        xFromPx = []; xlim = [NaN NaN]; okX = false; cf = [NaN NaN];
    end
    if numel(vy) >= 2
        [cfy, rmsy] = fitLine(py, vy);
        out.yTicks = vy; out.yRows = py; out.yRes = rmsy;
        yFromPx = @(q) cfy(1)*q + cfy(2);
        ylim = sort([yFromPx(ax.rowTop), yFromPx(ax.rowBottom)]);
        okY = rmsy <= opts.maxResid;
    else
        yFromPx = []; ylim = [NaN NaN]; okY = false; cfy = [NaN NaN];
    end

    out.txRaw = tx; out.tyRaw = ty;
    if ~okX && ~okY
        out.note = sprintf('OCR 刻度不足或残差过大（X:%d点 RMS%.2f，Y:%d点 RMS%.2f）', ...
            numel(vx), out.xRes, numel(vy), out.yRes);
        return;
    end

    % ---- 不可靠的一侧退回"轴框即范围"的保守估计 ----
    if ~okX
        xlim = [ax.colLeft, ax.colRight];      % 占位，调用方应改用手填
        xFromPx = []; 
    end
    if ~okY
        ylim = [ax.rowBottom, ax.rowTop];
        yFromPx = [];
    end

    out.cal = struct('xFromPx',xFromPx,'yFromPx',yFromPx, ...
                     'xlim',xlim,'ylim',ylim,'method','ocr-labels','confidence',1);
    out.ok = okX && okY;
    out.note = sprintf(['OCR 拟合：X 用 %d 个刻度(RMS %.2f)，Y 用 %d 个刻度(RMS %.2f)；' ...
        '外推到轴框边界得 X[%.3g, %.3g] Y[%.3g, %.3g]'], ...
        numel(vx), out.xRes, numel(vy), out.yRes, xlim, ylim);
end

%
function [v, pos, raw] = itemsToTicks(r, offX, offY, which)
%ITEMSTOTICKS  把 OCR 结果整理成"数值 + 像素位置"
%
%   Windows OCR 常把一个数拆成多个 token：实测 "0.2" 会被读成
%     "0"、"."、"2" 三个词，各自带独立坐标。所以必须先按位置归并
%     （同一刻度的 token 彼此很近），再拼字符串转数值；
%     否则会把 "0" 和 "2" 当成两个刻度，标定直接错。
    v = []; pos = []; raw = {};
    if isempty(r.items), return; end
    it = r.items;
    n = numel(it);
    % 1) 算出每个 token 的位置（沿轴方向）与横向范围
    c = zeros(1,n); lo = zeros(1,n); hi = zeros(1,n); txt = cell(1,n);
    for k = 1:n
        t = strtrim(char(string(it(k).text)));
        txt{k} = t;
        raw{end+1} = t; %#ok<AGROW>
        if strcmp(which,'x')
            lo(k) = it(k).x + offX - 1;  hi(k) = lo(k) + it(k).w;
            c(k)  = (lo(k) + hi(k)) / 2;
        else
            lo(k) = it(k).y + offY - 1;  hi(k) = lo(k) + it(k).h;
            c(k)  = (lo(k) + hi(k)) / 2;
        end
    end
    [c, o] = sort(c); lo = lo(o); hi = hi(o); txt = txt(o);
    % 2) 按"下一个 token 离当前组很近"归并成刻度
    gapMax = 26;                       % 同一刻度内 token 的最大间距（px）
    g = 1; gs = 1;
    for k = 2:(n+1)
        if k > n || (c(k) - c(k-1)) > gapMax
            seg = gs:(k-1);
            s = strjoin(txt(seg), '');
            s = regexprep(s, '[^0-9\.\-]', '');
            val = str2double(s);
            if ~isnan(val) && ~isempty(s)
                v(end+1) = val; %#ok<AGROW>
                % 位置取整组的中位，减少单个 token 框误差
                pos(end+1) = median(c(seg)); %#ok<AGROW>
            end
            gs = k; g = g + 1; %#ok<NASGU>
        end
    end
    % 3) 去掉重复位置（同一刻度被读两次）
    if numel(pos) > 1
        [pos, o2] = sort(pos); v = v(o2);
        keep = [true, diff(pos) > 6];
        pos = pos(keep); v = v(keep);
    end
end

%
function [cf, rms] = fitLine(px, val)
%FITLINE  最小二乘拟合 值 = cf(1)*像素 + cf(2)
    X = [px(:), ones(numel(px),1)];
    cf = X \ val(:);
    r = val(:) - X*cf;
    rms = sqrt(mean(r.^2));
end
