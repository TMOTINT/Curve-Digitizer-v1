function [Y, stat] = extractLineOnly(mask, colRange, rowRange, yStart, opts)
%EXTRACTLINEONLY  从"曲线 + 数据点标记 + 误差棒 + 图例"里只提取曲线。
%
%   为什么不做逐列追踪：
%   曾经用"从种子出发逐列推进、每列只在上一列附近找细游程"的做法。
%   实测在起点附近被标记点堵住时就断了（某图蓝色起点附近连续 29 列
%   被标记/误差棒占据，结果只观测到 8 列，整条曲线失败）。
%
%   现在的做法：全局候选 + 稳健拟合（不需要追踪）
%     1) 收集所有列里的"细游程中心"作为候选点。
%        细游程 = 线（2~4 px）；高游程 = 标记点/误差棒（十几 px 以上）。
%     2) 对全部候选做稳健多项式拟合（迭代剔除离群），得到曲线趋势。
%        标记点残余、误差棒上下端、图例样本线都偏离这个趋势，被自动剔除。
%     3) 用最终拟合曲线给出每一列的值 —— 缺列（被点挡住、虚线间隔）
%        自然被内插补上。
%     4) 拟合只在候选点的横向范围内进行，不外推（实测外推会炸到 1e6）。
%
%   这样既不依赖线宽的绝对阈值（只用来区分"细/粗"这一大类），
%   也不依赖追踪顺序，对起点被堵、虚线、图例都稳。
%
%   用法:
%     [Y, stat] = extractLineOnly(mask, [c0 c1], [r0 r1], yStart, opts)
%
%   opts:
%     margin     向内缩进像素数，避开刻度线（默认 8）
%     thinMax    细游程高度上限(px)，超过视为标记/误差棒（默认 7）
%     fitOrder   趋势多项式阶数（默认 4）
%     trimK      迭代剔除阈值：偏离趋势超过 trimK*RMS 的点剔除（默认 3）
%     trimIters  迭代次数（默认 3）
%     flatThresh 起伏小于几 px 判为水平参考线（默认 3）
%     straightTol 直线残余比阈值，超过则不是曲线（默认 0.012）
%
%   返回 Y：列数长度行号向量（内插范围内有值，范围外为 NaN）
%   stat: .nCand 候选点数 .nIn 内点数 .nFilled 内插列数 .nThick 粗游程列数
%         .bendRatio 弯曲度 .isStraight 是否判为直线

    if nargin < 5, opts = struct(); end
    if ~isfield(opts,'margin'),     opts.margin = 8;     end
    if ~isfield(opts,'thinMax'),    opts.thinMax = 7;    end
    if ~isfield(opts,'fitOrder'),   opts.fitOrder = 4;   end
    if ~isfield(opts,'trimK'),      opts.trimK = 3;      end
    if ~isfield(opts,'trimIters'),  opts.trimIters = 3;  end
    if ~isfield(opts,'flatThresh'), opts.flatThresh = 3; end
    if ~isfield(opts,'straightTol'),opts.straightTol = 0.012; end

    c0 = colRange(1); c1 = colRange(2);
    r0 = rowRange(1); r1 = rowRange(2);
    nCol = c1 - c0 + 1;

    stat = struct('nCand',0,'nIn',0,'nFilled',0,'nThick',0, ...
                  'bendRatio',NaN,'isStraight',false);
    Y = nan(nCol,1);

    % ---- 第0步：向内缩进，避开刻度线与刻度标记 ----
    mg = opts.margin;
    c0i = c0+mg; c1i = c1-mg; r0i = r0+mg; r1i = r1-mg;
    if c0i >= c1i || r0i >= r1i
        c0i = c0; c1i = c1; r0i = r0; r1i = r1;
    end

    % ---- 第1步：收集所有列的"细游程中心"作为候选 ----
    xs = []; ys = [];
    nThick = 0;
    for cc = c0i:c1i
        col = mask(r0i:r1i, cc);
        if ~any(col), continue; end
        v = col(:)';
        e = diff([false, v, false]);
        ss = find(e==1); ee = find(e==-1)-1;
        got = false;
        for k = 1:numel(ss)
            hgt = ee(k)-ss(k)+1;
            if hgt <= opts.thinMax
                xs(end+1,1) = cc; %#ok<AGROW>
                ys(end+1,1) = mean(ss(k):ee(k)) + (r0i-r0); %#ok<AGROW>
                got = true;
            end
        end
        if ~got && any(ee-ss+1 > opts.thinMax), nThick = nThick+1; end
    end
    stat.nCand = numel(xs);
    stat.nThick = nThick;
    if numel(xs) < opts.fitOrder + 3, return; end

    % ---- 第2步：稳健多项式拟合（迭代剔除离群）----
    % 用多项式表达"整条曲线的趋势"：标记点残余、误差棒端点、图例样本线
    % 都不在这个趋势上，会被自动剔除。
    order = opts.fitOrder;
    if numel(unique(xs)) < order + 2
        order = max(1, numel(unique(xs)) - 1);
    end
    inl = true(size(xs));
    for it = 1:opts.trimIters
        p = polyfit(xs(inl), ys(inl), order);
        resid = ys - polyval(p, xs);
        r = resid(inl);
        s = std(r);
        if s <= 0, break; end
        newInl = abs(resid) <= max(opts.trimK*s, 2);
        if sum(newInl) < order + 3, break; end
        if isequal(newInl, inl), break; end
        inl = newInl;
    end
    stat.nIn = sum(inl);
    if stat.nIn < order + 3, return; end
    p = polyfit(xs(inl), ys(inl), order);

    % ---- 第3步：在内点范围内给出每一列的值（内插，不外推）----
    lo = min(xs(inl)); hi = max(xs(inl));
    jlo = max(1, lo - c0 + 1);
    jhi = min(nCol, hi - c0 + 1);
    if jhi > jlo
        colsAll = (jlo:jhi)';
        Y(colsAll) = polyval(p, colsAll + c0 - 1);
        stat.nFilled = jhi - jlo + 1;
    end

    % ---- 第4步：判断是曲线还是直线（参考线/点画线）----
    obs = find(~isnan(Y));
    if numel(obs) >= 10
        spanY = max(Y(obs)) - min(Y(obs));
        spanX = obs(end) - obs(1);
        if spanX > 0
            pl = polyfit(obs, Y(obs), 1);
            stat.bendRatio = std(Y(obs) - polyval(pl,obs)) / max(1,spanX);
            if spanY < opts.flatThresh || stat.bendRatio < opts.straightTol
                stat.isStraight = true;
            end
        end
    end
end
