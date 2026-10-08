function [X, Y, info] = extractByColumns(I, ax, cal, seeds, opts)
%EXTRACTBYCOLUMNS  按列直接测量曲线（比区域生长追踪准得多、也快得多）。
%
%   为什么换掉"追踪"：
%   实测对比过两条独立途径取同一条曲线：
%       区域生长追踪  ->  141 点，且与逐列测量中位差 69.8 px（占满量程 20%）
%       逐列测量      ->  427 点（该有 427 列），稳定
%   追踪的问题在于"沿掩膜贪婪前进"，遇到噪声/交叉/图例就跳到别的线上。
%   而曲线在图上本来就是"每一列一簇像素"，直接按列取簇中心就是最准的。
%
%   本函数的做法（每列一簇，全程有连续性约束）：
%     1) 建立"该曲线颜色"的像素掩膜；
%     2) 用种子点确定起始列与该列的簇；
%     3) 向左、向右逐列推进，每列只在"上一列中心附近"的簇里挑，
%        保证不会跳到远处的另一条同色曲线上；
%     4) 遇到断裂允许跳过少量列（虚线、标记符号造成的空洞）。
%
%   用法:
%       [X,Y] = extractByColumns(I, ax, cal, [x y])            % 单个种子
%       [X,Y] = extractByColumns(I, ax, cal, [x1 y1; x2 y2])   % 多个种子
%       [X,Y,info] = extractByColumns(..., struct('colorTol',70))
%
%   返回 X、Y 为 N×1（按 X 升序去重后的单值曲线）；多种子时返回 cell。
%   info(k) 含 .mask .nPts .gaps .jumps

    if nargin < 5, opts = struct(); end
    if ~isfield(opts,'colorTol'), opts.colorTol = 70;  end
    if ~isfield(opts,'maxGap'),   opts.maxGap = 10;    end  % 允许跳过的空列
    % 相邻列中心的最大跃变：必须按斜率自适应。曲线在起始段常常近乎垂直，
    % 一列跨十几像素很正常；容差给死了就会把陡峭段整段丢掉（实测过）。
    if ~isfield(opts,'maxJump'),  opts.maxJump = 28;   end
    if ~isfield(opts,'minPix'),   opts.minPix = 1;     end
    % lineOnly：只取"线"，剔除散点标记与点画符号。默认开启。
    %   判据是"连续趋势"，不是线宽 —— 实测线宽分不开（标记点的短横线
    %   和曲线一样细）。分不开的重叠段用曲线拟合补回来。
    if ~isfield(opts,'lineOnly'), opts.lineOnly = true; end
    if ~isfield(opts,'marginInset'), opts.marginInset = 8;   end % 避让刻度线
    if ~isfield(opts,'maxGapLine'),  opts.maxGapLine = 60;   end
    if ~isfield(opts,'fitOrder'),    opts.fitOrder = 4;      end

    D = double(I);
    [H, W, ~] = size(D);
    c0 = max(1, round(ax.colLeft)+1);
    c1 = min(W, round(ax.colRight)-1);
    r0 = max(1, round(ax.rowTop)+1);
    r1 = min(H, round(ax.rowBottom)-1);

    multi = size(seeds,1) > 1;
    X = {}; Y = {};
    % 字段顺序必须与后面 struct(...) 完全一致，否则追加会报"下标赋值不匹配"
    info = struct('mask',{},'nPts',{},'gaps',{},'jumps',{}, ...
                  'pxCols',{},'pxRows',{});

    for si = 1:size(seeds,1)
        sd = seeds(si,:);
        xi = max(c0, min(c1, round(sd(1))));
        yi = max(r0, min(r1, round(sd(2))));
        seedCol = reshape(D(yi,xi,:),1,3);

        % ---- 掩膜：颜色接近种子，且限制在轴框内 ----
        dr = D(:,:,1)-seedCol(1); dg = D(:,:,2)-seedCol(2); db = D(:,:,3)-seedCol(3);
        m = (dr.^2 + dg.^2 + db.^2) <= opts.colorTol^2;
        m(:, [1:c0-1, c1+1:W]) = false;
        m([1:r0-1, r1+1:H], :) = false;

        % ---- 起始列：若种子列没掩膜，就近找有掩膜的列 ----
        if ~any(m(:,xi))
            found = false;
            for dlt = 1:15
                for cand = [xi-dlt, xi+dlt]
                    if cand>=c0 && cand<=c1 && any(m(:,cand))
                        xi = cand; found = true; break;
                    end
                end
                if found, break; end
            end
            if ~found
                X{end+1} = []; Y{end+1} = []; %#ok<AGROW>
                info(end+1) = struct('mask',m,'nPts',0,'gaps',0,'jumps',0,'pxCols',[],'pxRows',[]); %#ok<AGROW>
                continue;
            end
        end

        % ---- 逐列推进（先向右、再向左） ----
        % lineOnly 模式：只在"细游程"里挑中心，粗块（散点标记）直接跳过，
        % 并允许跨过更长的空缺（点占位、虚线间隔）。
        Yfull = nan(1, W);
        ci2 = struct('nGap',0,'nSkipped',0);
        if opts.lineOnly
            % 判据是连续趋势（不是线宽）；分不开的重叠段用拟合补回来
            [Ytmp, ci2] = extractLineOnly(m, [c0 c1], [r0 r1], yi, ...
                struct('margin', opts.marginInset, ...
                       'maxGap', opts.maxGapLine, ...
                       'maxJump', opts.maxJump + 6, ...
                       'fitOrder', opts.fitOrder));
            centers = nan(1, W);
            n = min(numel(Ytmp), W - c0 + 1);
            centers(c0:c0+n-1) = Ytmp(1:n);
            gaps = ci2.nFilled;      % 内插补出的列数
            jumps = ci2.nThick;      % 因"游程过高"（标记/误差棒）跳过的列数
            isStraight = ci2.isStraight;
            bendRatio = ci2.bendRatio;
            if isStraight
                fprintf(['  [extractByColumns] 该候选被判为**直线**（弯曲度 %.4f），' ...
                         '更像标定参考线/点画线，不作为曲线数据\n'], bendRatio);
            else
                fprintf(['  [extractByColumns] 判为曲线（弯曲度 %.4f，候选 %d / 内点 %d，' ...
                         '内插 %d 列，跳过标记列 %d）\n'], ...
                         bendRatio, ci2.nCand, ci2.nIn, ci2.nFilled, ci2.nThick);
            end
        else
            centers(xi) = pickCluster(m(:,xi), yi, r0, opts.minPix);
            gaps = 0; jumps = 0;
            for dir = [1, -1]
                last = centers(xi);
                miss = 0;
                c = xi;
                while true
                    c = c + dir;
                    if c < c0 || c > c1, break; end
                    yc = pickCluster(m(:,c), last, r0, opts.minPix);
                    if isempty(yc)
                        miss = miss + 1;
                        if miss > opts.maxGap, break; end
                        continue;
                    end
                    if abs(yc - last) > opts.maxJump
                        % 这一列的中心离得太远，判为跳到了别的线上，丢弃
                        jumps = jumps + 1;
                        miss = miss + 1;
                        if miss > opts.maxGap, break; end
                        continue;
                    end
                    if miss > 0, gaps = gaps + 1; end
                    miss = 0;
                    centers(c) = yc;
                    last = yc;
                end
            end
        end

        % ---- 组装并归约成单值曲线 ----
        cc = find(~isnan(centers));
        if isempty(cc)
            X{end+1} = []; Y{end+1} = []; %#ok<AGROW>
            info(end+1) = struct('mask',m,'nPts',0,'gaps',gaps,'jumps',jumps,'pxCols',[],'pxRows',[]); %#ok<AGROW>
            continue;
        end
        xc = cal.xFromPx(cc(:));
        yc = cal.yFromPx(centers(cc)');
        [xc, o] = sort(xc); yc = yc(o);
        % 同时保存像素坐标（画对照图用，也便于核对）
        pxCols = cc(o);
        pxRows = centers(cc(o))';
        X{end+1} = xc; Y{end+1} = yc; %#ok<AGROW>
        info(end+1) = struct('mask',m,'nPts',numel(xc),'gaps',gaps, ...
                             'jumps',jumps,'pxCols',pxCols,'pxRows',pxRows); %#ok<AGROW>
    end

    if ~multi
        X = X{1}; Y = Y{1}; info = info(1);
    end
end

%
function yc = pickCluster(colMask, yRef, r0, minPix)
%PICKCLUSTER  在某一列的掩膜里，取"离 yRef 最近的那一簇"的中心行。
%   这是保证不跳线的关键：只在参照位置附近的簇里选，而不是取全局中心。
    if ~any(colMask), yc = []; return; end
    rows = find(colMask);
    % 标准游程起止：两侧各补一个 false 再找跳变，避免漏掉首尾
    v = colMask(:)';
    e = diff([false, v, false]);
    ss = find(e == 1);
    ee = find(e == -1) - 1;
    if isempty(ss)
        ss = rows(1); ee = rows(end);
    end
    best = []; bestD = inf;
    for k = 1:numel(ss)
        rs = ss(k):ee(k);
        if numel(rs) < minPix, continue; end
        cen = mean(rs) + r0 - 1;
        dd = abs(cen - yRef);
        if dd < bestD, bestD = dd; best = cen; end
    end
    yc = best;
end
