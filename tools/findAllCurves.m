function cand = findAllCurves(I, ax, opts)
%FINDALLCURVES  找出图中的所有曲线（自动区分不同颜色 / 同色系不同深浅）。
%
%   这是"区分并标注不同颜色曲线"的推荐入口。
%
%   用法: cand = findAllCurves(I, ax)
%         cand = findAllCurves(I, ax, struct('maxCurves', 14))
%
%   返回 cand(k)：
%     .color   代表色 RGB（0-255），用于与图例配色
%     .seed    [x y] 建议的种子点（追踪起点）
%     .size    像素数
%     .yMean   平均行号（用于排序/命名）
%     .from    'color' | 'scan' | 'slice' 候选来源（便于排错）
%     .spanX   横向跨度（像素）
%     .kind    'curve'（连续走线）或 'scatter'（散点序列）
%
%   ================== 三条并行的方法，为什么都要跑 ==================
%   方法一 颜色直方图 colorCurves
%       对"异色曲线"（蓝+红）很准；对"同色系多条"会把它们并成一条
%       —— 抗锯齿把颜色糊成连续分布，直方图分不出峰。
%   方法二 多位置扫描 scanCurveCandidates
%       对"同色系多曲线"很准（靠空间分离数条数）；
%       但对"同色号的散点+拟合线"会把它们连成一条，
%       而且在曲线一端汇聚时会把多条并成一条、还混出一个颜色是平均值的
%       假候选（实测 Fig.3A 出现过 RGB[68 196 68]、3831 px 的假货）。
%   方法三 列切片 + 连续性延伸 scanBySlices
%       先在"曲线分得最开的那一列"取种子，再按颜色+纵向连续性向两边延伸，
%       专门解决"一端汇聚"的同色系。
%
%   ================== 三道过滤，每一道都是实测逼出来的 ==================
%   ① classifyAndFilter：判"连续曲线 / 散点 / 碎片噪声"。
%      实测过"线宽"判据没用 —— 混色像素又细又广（421 列、中位厚 2px），
%      由圆点组成的真曲线反而很厚（中位 13px），厚度分不开真假。
%      可靠的是连续性：真曲线几乎每列都有像素且相邻列连得上。
%      实测某面板的"红色"是碎片噪声：2079 像素分成 166 个块、面积中位 2px
%      —— 它不是数据系列，是黑色曲线的抗锯齿边。
%   ② filterBySpan：剔除"多条曲线混色拼出来的假候选"。
%      假候选在每个采样位置都自洽，但整体是断开的。三条判据：
%        · 有一条横贯轴框的长连通块（实线），或
%        · 列覆盖并集够宽 且 覆盖列之间空隙很小（虚线的样子）
%        · 像素密度 = 像素数/覆盖列数 不能太低
%      最后一条最灵：假候选跨 500 多列却只有 0.4 px/列（真曲线 0.7~0.8），
%      因为它只是几条不同深浅曲线在个别列上的零碎混色。
%   ③ 合并去重：颜色接近 且 位置接近才算同一条。
%      只按颜色合并会把"同色号的散点与拟合线"错误合并（位置分得很开）。
%
%   实测能力与边界：
%       蓝/红两条异色曲线    -> 2/2    准确
%       7 档同色系绿色曲线  -> 7/7    准确
%       同色系 + 一端汇聚    -> 可用，但可能少认几条或给出重复候选
%       黑色曲线与深色曲线同图 -> 分不开（明度重叠），请手动点选
%       仅靠 marker 区分的同色系列 -> 无法自动分开，请手动点选
%   分不开的那些，界面会在提取后提示"哪几条结果几乎重合"，改手动点选即可。
%
%   依赖：MATLAB 基础功能。配套 colorCurves.m / scanCurveCandidates.m /
%         scanBySlices.m / findLegend.m。

    if nargin < 3, opts = struct(); end
    if ~isfield(opts,'maxCurves'), opts.maxCurves = 14; end
    % 默认不做"追踪验证"：实测它容易把真曲线也滤掉（追踪对种子点位置敏感，
    % 而种子点未必落在曲线最干净处）。改用扫描自带的 spanX 做判据 ——
    % 扫描本来就只有"跨多个位置稳定出现"的组合才算候选，判据更可靠。
    if ~isfield(opts,'verify'),    opts.verify = false; end
    if ~isfield(opts,'verifySpan'), opts.verifySpan = 0.30; end
    if ~isfield(opts,'minSpanFrac'), opts.minSpanFrac = 0; end
    % 线宽/跨度筛选（剔除散点、色带等非曲线）
    if ~isfield(opts,'colorTolThick'), opts.colorTolThick = 60;  end
    if ~isfield(opts,'thickFactor'),   opts.thickFactor = 2.5;   end
    if ~isfield(opts,'minColFrac'),    opts.minColFrac = 0.30;   end
    % 连续性检验参数
    if ~isfield(opts,'maxGapLink'),    opts.maxGapLink = 12;     end
    if ~isfield(opts,'maxJumpLink'),   opts.maxJumpLink = 30;    end
    % 曲线 / 散点 判定阈值
    if ~isfield(opts,'curveFrac'),      opts.curveFrac = 0.50;   end
    if ~isfield(opts,'minBlobArea'),    opts.minBlobArea = 12;   end
    if ~isfield(opts,'maxScatterBlobs'), opts.maxScatterBlobs = 120; end
    % 跨度/密度过滤阈值
    if ~isfield(opts,'spanFrac'),      opts.spanFrac = 0.35;     end
    if ~isfield(opts,'unionSpanFrac'), opts.unionSpanFrac = 0.50; end
    if ~isfield(opts,'maxCoverGap'),   opts.maxCoverGap = 0.08;  end
    if ~isfield(opts,'minDensity'),    opts.minDensity = 0.9;    end
    if ~isfield(opts,'minElong'),      opts.minElong = 2.5;      end
    if ~isfield(opts,'quiet'),         opts.quiet = false;        end
    if ~isfield(opts,'cal') || isempty(opts.cal)
        % 追踪只需要标定来做坐标换算；这里给恒等映射即可，
        % 因为本轮只关心"路径在像素上行进多宽"，与数值无关。
        opts.cal = struct('xFromPx', @(q) q, 'yFromPx', @(q) q);
    end

    cand = struct('color', {}, 'size', {}, 'seed', {}, 'yMean', {}, ...
                  'spanX', {}, 'from', {});

    % ---------- 方法一：颜色直方图 ----------
    try
        c1 = colorCurves(I, ax, struct('maxCurves', opts.maxCurves, ...
                                       'splitShades', false));
    catch
        c1 = [];
    end
    for k = 1:numel(c1)
        cand(end+1) = struct('color', c1(k).color, 'size', c1(k).size, ...
            'seed', c1(k).seed, 'yMean', c1(k).yMean, 'spanX', NaN, ...
            'from', 'color'); %#ok<AGROW>
    end

    % ---------- 方法二：多位置扫描 ----------
    try
        c2 = scanCurveCandidates(I, ax, opts);
    catch
        c2 = [];
    end
    for k = 1:numel(c2)
        cand(end+1) = struct('color', c2(k).color, 'size', c2(k).size, ...
            'seed', c2(k).seed, 'yMean', c2(k).yMean, 'spanX', c2(k).spanX, ...
            'from', 'scan'); %#ok<AGROW>
    end

    % ---------- 方法三：按列切片 + 连续性延伸 ----------
    try
        c3 = scanBySlices(I, ax, opts);
    catch
        c3 = [];
    end
    for k = 1:numel(c3)
        cand(end+1) = struct('color', c3(k).color, 'size', c3(k).size, ...
            'seed', c3(k).seed, 'yMean', c3(k).yMean, 'spanX', c3(k).spanX, ...
            'from', c3(k).from); %#ok<AGROW>
    end

    % ---------- 方法四：轴框端点取种子（专治"一端汇聚的曲线族"）----------
    %   实测 Fig.3D 的 9 档绿色 V 形族全部在 x≈0 汇聚，前三种方法给出的种子
    %   几乎都落在汇聚点 —— 那里多条曲线重合，DP 无从区分，只能提到一条。
    %   在分得最开的另一端取种子，每个颜色-位置组合就唯一对应一条曲线。
    if ~isfield(opts,'useEdgeSeed') || opts.useEdgeSeed
        try
            o4 = struct('side', 'right');
            if isfield(opts,'edgeSide') && ~isempty(opts.edgeSide), o4.side = opts.edgeSide; end
            if isfield(opts,'edgeSideFrac') && ~isempty(opts.edgeSideFrac), o4.sideFrac = opts.edgeSideFrac; end
            c4 = seedFromEdge(I, ax, o4);
        catch
            c4 = [];
        end
        for k = 1:numel(c4)
            cand(end+1) = struct('color', c4(k).color, 'size', c4(k).size, ...
                'seed', c4(k).seed, 'yMean', c4(k).yMean, 'spanX', c4(k).spanX, ...
                'from', c4(k).from); %#ok<AGROW>
        end
    end

    if isempty(cand), return; end

    % ---------- ⓪ 先剔除"图例样本"造成的假候选 ----------
    %   为什么必须放在最前面：图例里的样本线（`—●—`）与真曲线同色同线宽，
    %   长度也够，任何按颜色/形状的判据都分不开它们。实测后果：
    %     · Fig.3C 实际只有 2 条曲线，却识别出 5 条（多出 2~3 个图例样本）；
    %     · Fig.3E 直接把图例当成了曲线。
    %   做法：先定位图例区域，凡"落在图例区域内的候选"一律丢掉；
    %   再把"颜色与图例样本色几乎一致"的候选也丢掉。
    if ~isfield(opts,'useLegend') || opts.useLegend
        try
            leg = findLegend(I, ax);
            if leg.found && ~isempty(leg.rect)
                R0 = leg.rect;
                nDrop = 0; ii = 1;
                while ii <= numel(cand)
                    sd = cand(ii).seed;
                    inLeg = sd(1) >= R0(1) && sd(1) <= R0(3) && ...
                            sd(2) >= R0(2) && sd(2) <= R0(4);
                    closeToSwatch = false;
                    for q = 1:size(leg.colors,1)
                        if norm(double(cand(ii).color) - double(leg.colors(q,:))) < 30
                            closeToSwatch = true; break;
                        end
                    end
                    if inLeg || closeToSwatch
                        cand(ii) = []; nDrop = nDrop + 1;
                    else
                        ii = ii + 1;
                    end
                end
                if nDrop > 0 && ~opts.quiet
                    fprintf(['  [findAllCurves] 剔除 %d 个"图例样本"候选' ...
                             '（图例区域 x%d-%d y%d-%d，%d 个样本色）\n'], ...
                        nDrop, round(leg.rect), size(leg.colors,1));
                end
            end
        catch
            % 图例检测失败不阻断主流程
        end
    end
    if isempty(cand), return; end

    % ---------- ① 连续性分类：曲线 / 散点 / 碎片噪声 ----------
    % 两类都保留：按需求，散点也要提取，只是要和曲线区分标注。
    cand = classifyAndFilter(cand, I, ax, opts);
    dbg = isfield(opts,'dbg') && opts.dbg;
    if dbg, dumpCand('① 连续性分类后', cand); end

    % ---------- ② 跨度 + 密度验证：剔除混色拼出来的假候选 ----------
    cand = filterBySpan(cand, I, ax, opts);
    if dbg, dumpCand('② 跨度密度过滤后', cand); end

    if isempty(cand), return; end

    % ---------- ③ 合并去重 ----------
    [~, o] = sort([cand.size], 'descend');
    cand = cand(o);
    keep = true(1, numel(cand));
    for a = 1:numel(cand)
        if ~keep(a), continue; end
        for b = a+1:numel(cand)
            if ~keep(b), continue; end
            dc = norm(double(cand(a).color) - double(cand(b).color));
            dy = abs(cand(a).yMean - cand(b).yMean);
            dx = abs(cand(a).seed(1) - cand(b).seed(1));
            % 同一曲线：颜色很像 且 纵向位置很近
            if dc < 40 && dy < 12
                keep(b) = false;
            elseif dc < 18 && dy < 30 && dx < 20
                % 容差从 25 收到 18：同色系的相邻深浅（如 [8 88 8] 与 [4 123 4]）
                % 色距只有 35 左右，再放宽就有把相邻两条合并的风险。
                keep(b) = false;
            end
        end
    end
    cand = cand(keep);
    if isempty(cand), return; end
    if dbg, dumpCand('③ 合并去重后', cand); end

    % ---------- ③b 抗锯齿晕归并 ----------
    %   合成真值基准测试抓到的关键问题（这是"同一条曲线被拆成好几个候选"
    %     的主因）：曲线核心色外圈有一圈抗锯齿晕，其颜色是核心色与白底的
    %     混合（实测核心 [0 255 0] 的晕是 [179 255 179]）。两路候选源都会
    %     把晕当成一条独立曲线报出来 —— 真值 3 条却报出 8 条。
    %   判据：若候选 A 的颜色与候选 B 色相接近（去掉灰度成分后差得不多），
    %         而 A 的饱和度明显低于 B，且两者在图上位置相近，则 A 是 B 的晕，
    %         丢弃 A、只留 B（更饱和的那个才是曲线本身）。
    keep2 = true(1, numel(cand));
    for a = 1:numel(cand)
        if ~keep2(a), continue; end
        ca = double(cand(a).color(:)');
        sa = max(ca) - min(ca);
        for b = 1:numel(cand)
            if a == b || ~keep2(b), continue; end
            cb = double(cand(b).color(:)');
            sb = max(cb) - min(cb);
            if sb <= sa + 60, continue; end            % b 必须明显更饱和
            if numel(ca) < 3 || numel(cb) < 3, continue; end
            ga = mean(ca); gb = mean(cb);
            chromaDist = max(abs((ca - ga) - (cb - gb)));   % 色相/方向差
            dy = abs(cand(a).yMean - cand(b).yMean);
            if chromaDist <= 90 && dy <= 25
                keep2(a) = false;                        % a 是 b 的晕
                break;
            end
        end
    end
    if any(~keep2) && ~opts.quiet
        fprintf('  [findAllCurves] 归并 %d 个"抗锯齿晕"候选（同色相但饱和度更低的）\n', ...
            nnz(~keep2));
    end
    cand = cand(keep2);
    if isempty(cand), return; end

    % 去掉明显是噪声的（像素太少）
    cand = cand([cand.size] >= 40);
    if isempty(cand), return; end

    % ---------- 用扫描跨度做基本过滤 ----------
    % 扫描候选自带 spanX。真曲线至少横跨轴框的一部分；只在一两个位置出现的
    % 小团（抗锯齿混合色、图例残留）跨度很小。颜色直方图来的候选没有 spanX，
    % 给 NaN 放行（它们按像素量已经筛过）。
    needPx = opts.minSpanFrac * (ax.colRight - ax.colLeft);
    ok = true(1, numel(cand));
    for k = 1:numel(cand)
        if ~isnan(cand(k).spanX) && cand(k).spanX < needPx
            ok(k) = false;
        end
    end
    cand = cand(ok);

    % ---------- 可选：追踪验证（默认关闭）----------
    if opts.verify && ~isempty(cand)
        minSpanPx = opts.verifySpan * (ax.colRight - ax.colLeft);
        keep = false(1, numel(cand));
        for k = 1:numel(cand)
            try
                r = curveTools('trace', I, ax, opts.cal, cand(k).seed, ...
                               struct('colorTol', 70, 'radius', 6, 'rankStep', 3));
                if ~isempty(r.pathPx)
                    sp = max(r.pathPx(:,1)) - min(r.pathPx(:,1));
                    cand(k).spanX = sp;
                    keep(k) = sp >= minSpanPx;
                end
            catch
                keep(k) = false;
            end
        end
        cand = cand(keep);
    end

    if isempty(cand), return; end

    % 超出数量上限时保留像素最多的若干条
    if numel(cand) > opts.maxCurves
        [~, o] = sort([cand.size], 'descend');
        cand = cand(o(1:opts.maxCurves));
    end

    % 按纵向位置排序（与图例顺序通常一致）
    [~, o] = sort([cand.yMean]);
    cand = cand(o);
end

%
function dumpCand(label, cand)
%DUMPCAND  诊断打印：候选的颜色 / 种子 / 像素数 / 来源
    fprintf('  [findAllCurves] %s：%d 条\n', label, numel(cand));
    for k = 1:numel(cand)
        sd = cand(k).seed;
        extra = '';
        if isfield(cand(k),'kind') && ~isempty(cand(k).kind)
            extra = sprintf(' kind=%s', cand(k).kind);
        end
        if isfield(cand(k),'linkedFrac') && ~isempty(cand(k).linkedFrac)
            extra = sprintf('%s link=%.2f', extra, cand(k).linkedFrac);
        end
        fprintf('      %2d: [%3d %3d %3d] seed [%4.0f %4.0f] size %5d%s\n', ...
            k, round(cand(k).color), sd, cand(k).size, extra);
    end
end

%
function cand = classifyAndFilter(cand, I, ax, opts)
%CLASSIFYANDFILTER  判定每个候选是"连续曲线"还是"散点"，并剔除碎片噪声。
%
%   两个量化指标（都在轴框内、按该候选颜色统计）：
%     linkedFrac  从种子出发逐列推进，能连出的列数 / 轴框列数
%                 -> 连续曲线高（>0.5），散点低，碎片噪声低
%     blobStat    连通块统计：块数、块面积中位数、最大块面积
%                 -> 碎片噪声：块数很多、中位面积只有 1~3 px
%                    散点标记：块数中等、每个块面积大（圆点形状）
%                    连续曲线：块数很少（理想 1 个）
%
%   分类规则：
%     linkedFrac >= curveFrac 且 最大块占主导        -> 'curve'
%     linkedFrac 低但块面积中位数够大（像标记点）     -> 'scatter'
%     其它（碎片化、面积小）                          -> 丢弃（噪声）
%
%   结果写入 cand(k).kind / .linkedFrac / .blobStat / .gapFrac。

    if isempty(cand), return; end
    D = double(I);
    W = size(D,2); H = size(D,1);
    c0 = max(1, round(ax.colLeft)+1);  c1 = min(W, round(ax.colRight)-1);
    r0 = max(1, round(ax.rowTop)+1);   r1 = min(H, round(ax.rowBottom)-1);
    spanCols = c1 - c0 + 1;

    keep = true(1, numel(cand));
    for k = 1:numel(cand)
        c = double(cand(k).color);
        dr = D(:,:,1)-c(1); dg = D(:,:,2)-c(2); db = D(:,:,3)-c(3);
        m = (dr.^2+dg.^2+db.^2) <= opts.colorTolThick^2;
        m(:, [1:c0-1, c1+1:W]) = false;
        m([1:r0-1, r1+1:H], :) = false;
        ms = m(r0:r1, c0:c1);

        % ---- 指标1：逐列连续性 ----
        [nLinked, nGap] = linkColumns(ms, cand(k).seed, c0, r0, opts);
        linkedFrac = nLinked / spanCols;

        % ---- 指标2：连通块统计 ----
        [nBlob, medArea, maxArea] = blobStats(ms);

        cand(k).linkedFrac = linkedFrac;
        cand(k).gapFrac = nGap / max(1, nLinked + nGap);
        cand(k).blobStat = [nBlob medArea maxArea];

        % ---- 分类 ----
        isCurve   = linkedFrac >= opts.curveFrac;
        looksLikeMarkers = medArea >= opts.minBlobArea && nBlob >= 2 && ...
                           nBlob <= opts.maxScatterBlobs;
        looksLikeNoise   = medArea < opts.minBlobArea && nBlob > opts.maxScatterBlobs;

        % ---- 指标3：连通块"细长比" = 曲线 vs 散点/标记 ----
        %   用户点出的问题："散点、曲线、标记点、虚线等互相影响"。
        %     曲线是一条又长又细的连通块；圆点标记是"短而粗"的块；
        %     散点是许多互不相连的小块。用最大块的"长/厚"比就能分开：
        %       曲线     -> 长/厚 很大（几十以上）
        %       圆点标记 -> 长/厚 接近 1
        %     这样即使连通块统计把标记数进去了，也能判掉。
        elong = elongOfLargest(ms);

        % ---- 指标4：虚线判据（空列是否"等间隔周期性"）----
        %   实测：虚线（参考线、onset 标记线）与曲线一样细、一样直，
        %   唯一区别是空列周期性出现。真曲线也可能有空洞，但空洞位置
        %   是随机的、不会等间隔。所以：空列数够多且间隔的离散度很小时，
        %   判为虚线。
        isDashed = false;
        if nGap >= 4 && nLinked > 0
            gaps = gapPositions(ms, cand(k).seed, c0, r0, opts);
            if numel(gaps) >= 4
                dg = diff(gaps);
                if ~isempty(dg) && median(dg) >= 2 && ...
                   std(dg) / max(1e-6, mean(dg)) < 0.35
                    isDashed = true;
                end
            end
        end
        cand(k).elong = elong;

        if isDashed
            cand(k).kind = 'dashed';        % 虚线：记下来但不丢弃（见下）
        elseif isCurve
            cand(k).kind = 'curve';
        elseif looksLikeMarkers
            cand(k).kind = 'scatter';
        elseif looksLikeNoise
            keep(k) = false;
        else
            keep(k) = false;
        end
    end
    cand = cand(keep);
end

%
function [nLinked, nGap] = linkColumns(ms, seed, c0, r0, opts)
%LINKCOLUMNS  从种子出发逐列推进，统计连出的列数与空列数
    nLinked = 0; nGap = 0;
    [~, Ws] = size(ms);
    xi = max(1, min(Ws, round(seed(1)) - c0 + 1));
    yi = max(1, min(size(ms,1), round(seed(2)) - r0 + 1));
    if ~any(ms(:,xi))
        found = false;
        for d = 1:12
            for cc = [xi-d, xi+d]
                if cc>=1 && cc<=Ws && any(ms(:,cc)), xi=cc; found=true; break; end
            end
            if found, break; end
        end
        if ~found, return; end
    end
    for dir = [1 -1]
        last = pickNear(ms(:,xi), yi, 1);      % 注意：ms 已是裁剪后坐标
        if isempty(last), continue; end
        nLinked = nLinked + 1;
        miss = 0; cc = xi;
        while true
            cc = cc + dir;
            if cc < 1 || cc > Ws, break; end
            yc = pickNear(ms(:,cc), last, 1);
            if isempty(yc) || abs(yc-last) > opts.maxJumpLink
                miss = miss + 1;
                if miss > opts.maxGapLink, break; end
                continue;
            end
            if miss > 0, nGap = nGap + miss; end
            miss = 0; nLinked = nLinked + 1; last = yc;
        end
    end
end

%
function e = elongOfLargest(m)
%ELONGOFLARGEST  最大连通块的"长/厚"比（曲线很大，圆点标记 ≈ 1）
%   曲线：跨几百列、每列 2~5 px 厚 -> e 很大（几十以上）；
%   圆点标记：跨十几列、厚十几 px -> e≈1；散点：许多互不相连的小碎块。
%   用游程连通域算最大块的包围盒；不另造一份连通域实现
%   （曾经另写一份，标号越界把整个候选发现打挂了）。
    e = 0;
    if ~any(m(:)), return; end
    bb = largestBlobBox(m);
    if isempty(bb), return; end
    lenC = bb(2) - bb(1) + 1;
    lenR = bb(4) - bb(3) + 1;
    if lenR <= 0, return; end
    e = lenC / lenR;
end

%
function bb = largestBlobBox(m)
%LARGESTBLOBBOX  面积最大的连通块的包围盒 [c0 c1 r0 r1]（游程 + 并查集）
    bb = [];
    if ~any(m(:)), return; end
    [H, ~] = size(m);
    parent = []; next = 0;
    allR = []; allC = []; allL = [];
    prevRuns = zeros(0,2); prevLab = zeros(0,1);
    for r = 1:H
        v = m(r,:);
        d = diff([false, v, false]);
        ss = find(d == 1); ee = find(d == -1) - 1;
        curLab = zeros(numel(ss),1);
        for k = 1:numel(ss)
            a = ss(k); b = ee(k);
            lab = 0;
            for p = 1:size(prevRuns,1)
                if prevRuns(p,2) >= a && prevRuns(p,1) <= b
                    if lab == 0
                        lab = prevLab(p);
                    else
                        ra = findRootLocal(parent, lab);
                        rb = findRootLocal(parent, prevLab(p));
                        if ra ~= rb, parent(max(ra,rb)) = min(ra,rb); end
                    end
                end
            end
            if lab == 0
                next = next + 1; parent(next) = next; lab = next; %#ok<AGROW>
            end
            curLab(k) = lab;
            allR(end+1) = r;    allC(end+1) = a; allL(end+1) = lab; %#ok<AGROW>
            allR(end+1) = r;    allC(end+1) = b; allL(end+1) = lab; %#ok<AGROW>
        end
        prevRuns = [ss(:) ee(:)];
        prevLab = curLab;
    end
    if isempty(allL), return; end
    roots = zeros(size(allL));
    for k = 1:numel(allL)
        roots(k) = findRootLocal(parent, allL(k));
    end
    u = unique(roots);
    bestArea = -1;
    for k = 1:numel(u)
        sel = roots == u(k);
        c0 = min(allC(sel)); c1 = max(allC(sel));
        r0 = min(allR(sel)); r1 = max(allR(sel));
        area = (c1-c0+1)*(r1-r0+1);
        if area > bestArea
            bestArea = area; bb = [c0 c1 r0 r1];
        end
    end
end

%
function r = findRootLocal(parent, k)
    if isempty(parent) || k < 1 || k > numel(parent), r = k; return; end
    r = k;
    while parent(r) ~= r && parent(r) >= 1 && parent(r) <= numel(parent)
        r = parent(r);
    end
end

%
function gaps = gapPositions(m, seed, c0, r0, opts)
%GAPPOSITIONS  沿曲线推进，记录"空列"的列号（用于判断虚线）
    gaps = [];
    [~, Ws] = size(m);
    xi = max(1, min(Ws, round(seed(1)) - c0 + 1));
    yi = max(1, min(size(m,1), round(seed(2)) - r0 + 1));
    if ~any(m(:,xi))
        found = false;
        for d = 1:12
            for cc = [xi-d, xi+d]
                if cc>=1 && cc<=Ws && any(m(:,cc)), xi=cc; found=true; break; end
            end
            if found, break; end
        end
        if ~found, return; end
    end
    last = pickNear(m(:,xi), yi, 1);
    if isempty(last), return; end
    miss = 0; cc = xi;
    while true
        cc = cc + 1;
        if cc > Ws, break; end
        yc = pickNear(m(:,cc), last, 1);
        if isempty(yc) || abs(yc-last) > opts.maxJumpLink
            miss = miss + 1;
            if miss > opts.maxGapLink, break; end
            continue;
        end
        if miss > 0
            gaps(end+1) = cc - miss; %#ok<AGROW>
        end
        miss = 0; last = yc;
    end
end

%
function [nBlob, medArea, maxArea] = blobStats(m)
%BLOBSTATS  连通块统计（4 邻域，游程 + 并查集，不用工具箱）
    nBlob = 0; medArea = 0; maxArea = 0;
    if ~any(m(:)), return; end
    [H, W] = size(m);
    parent = []; next = 0;
    allS = []; allE = []; allL = [];
    prevRuns = zeros(0,2); prevLab = zeros(0,1);
    for r = 1:H
        v = m(r,:);
        d = diff([false, v, false]);
        ss = find(d==1); ee = find(d==-1)-1;
        cur = [ss(:), ee(:)];
        curLab = zeros(size(cur,1),1);
        for j = 1:size(cur,1)
            hit = [];
            for kk = 1:size(prevRuns,1)
                if cur(j,2) >= prevRuns(kk,1)-1 && cur(j,1) <= prevRuns(kk,2)+1
                    hit(end+1) = prevLab(kk); %#ok<AGROW>
                end
            end
            if isempty(hit)
                next = next + 1; parent(next) = next;
                curLab(j) = next;
            else
                curLab(j) = hit(1);
                for kk = 2:numel(hit)
                    ra = root(parent, hit(1)); rb = root(parent, hit(kk));
                    if ra ~= rb, parent(max(ra,rb)) = min(ra,rb); end
                end
            end
        end
        prevRuns = cur; prevLab = curLab;
        if ~isempty(cur)
            allS=[allS; cur(:,1)]; allE=[allE; cur(:,2)]; allL=[allL; curLab]; %#ok<AGROW>
        end
    end
    for kk = 1:numel(allL), allL(kk) = root(parent, allL(kk)); end
    uL = unique(allL);
    nBlob = numel(uL);
    areas = zeros(nBlob,1);
    for kk = 1:nBlob
        sel = (allL == uL(kk));
        areas(kk) = sum(allE(sel) - allS(sel) + 1);   % 每行像素数之和 = 面积
    end
    medArea = median(areas);
    maxArea = max(areas);
end

function r = root(parent, x)
    r = x;
    while parent(r) ~= r, r = parent(r); end
end

%
function cand = filterBySpan(cand, I, ax, opts)
%FILTERBYSPAN  剔除"由多条曲线混色拼出来"的假候选。
%
%   假候选的特征：它在各个采样位置都自洽，但整体是断开的 —— 颜色掩膜里
%   只有一堆互不相连的短块，且这些块在横向上并不真的连成一条线。
%   真曲线（含虚线）满足下面任一条：
%     · 有一条横贯轴框的长连通块（实线）；
%     · 所有块的列覆盖并集很宽，且相邻覆盖列之间的最大空隙很小
%       （虚线：一段一段，但段与段挨得近）。
%   再加一条最灵的判据：像素密度 = 像素数 / 覆盖列数。
%   实测 Fig.3A 的假候选（RGB[68 196 68]，3831 px）跨 500 多列却只有
%   0.4 px/列，而真曲线是 0.7~0.8 px/列 —— 因为它只是几条不同深浅曲线在
%   个别列上的零碎混色，并不真的沿着某一条线走。
    if isempty(cand), return; end
    D = double(I);
    W = size(D,2); H = size(D,1);
    c0 = max(1, round(ax.colLeft)+1);  c1 = min(W, round(ax.colRight)-1);
    r0 = max(1, round(ax.rowTop)+1);   r1 = min(H, round(ax.rowBottom)-1);
    spanCols = c1 - c0 + 1;
    if spanCols < 5, return; end
    minSpan  = max(opts.spanFrac * spanCols, 20);
    minUnion = max(opts.unionSpanFrac * spanCols, 30);
    maxGap   = max(opts.maxCoverGap * spanCols, 12);
    keep = true(1, numel(cand));
    for k = 1:numel(cand)
        c = double(cand(k).color);
        dr = D(:,:,1)-c(1); dg = D(:,:,2)-c(2); db = D(:,:,3)-c(3);
        m = (dr.^2+dg.^2+db.^2) <= opts.colorTolThick^2;
        ms = m(r0:r1, c0:c1);
        if ~any(ms(:)), keep(k) = false; continue; end
        [span, unionSpan, gapMax, nCover] = spanStats(ms);
        if span >= minSpan, continue; end
        if unionSpan >= minUnion && gapMax <= maxGap, continue; end
        if nCover > 0 && nnz(ms)/nCover >= opts.minDensity, continue; end
        keep(k) = false;
    end
    cand = cand(keep);
end

%
function [span, unionSpan, gapMax, nCover] = spanStats(m)
%SPANSTATS  连通块的横向跨度、列覆盖并集、最大空隙、覆盖列数
    [H, W] = size(m);
    span = 0; unionSpan = 0; gapMax = inf; nCover = 0;
    if ~any(m(:)), return; end
    parent = []; next = 0;
    allS = []; allE = []; allC = []; allL = [];
    prevRuns = zeros(0,2); prevLab = zeros(0,1);
    for r = 1:H
        v = m(r,:);
        d = diff([false, v, false]);
        ss = find(d==1); ee = find(d==-1)-1;
        cur = [ss(:), ee(:)];
        curLab = zeros(size(cur,1),1);
        for j = 1:size(cur,1)
            hit = [];
            for kk = 1:size(prevRuns,1)
                if cur(j,2) >= prevRuns(kk,1)-1 && cur(j,1) <= prevRuns(kk,2)+1
                    hit(end+1) = prevLab(kk); %#ok<AGROW>
                end
            end
            if isempty(hit)
                next = next + 1; parent(next) = next;
                curLab(j) = next;
            else
                curLab(j) = hit(1);
                for kk = 2:numel(hit)
                    ra = root(parent, hit(1)); rb = root(parent, hit(kk));
                    if ra ~= rb, parent(max(ra,rb)) = min(ra,rb); end
                end
            end
        end
        prevRuns = cur; prevLab = curLab;
        if ~isempty(cur)
            allS=[allS; cur(:,1)]; allE=[allE; cur(:,2)]; %#ok<AGROW>
            allC=[allC; (cur(:,1)+cur(:,2))/2]; allL=[allL; curLab]; %#ok<AGROW>
        end
    end
    for kk = 1:numel(allL), allL(kk) = root(parent, allL(kk)); end
    uL = unique(allL);
    spans = zeros(numel(uL),1);
    covered = false(1, W);
    for kk = 1:numel(uL)
        sel = find(allL == uL(kk));
        spans(kk) = max(allC(sel)) - min(allC(sel)) + 1;
        for q = sel'
            covered(allS(q):allE(q)) = true;      % 该块覆盖到的列
        end
    end
    span = max(spans);
    if any(covered)
        cc2 = find(covered);
        nCover = numel(cc2);
        unionSpan = cc2(end) - cc2(1) + 1;
        % 相邻"覆盖列"之间的最大空隙：虚线也只在几像素以内，散块则很大
        gaps = diff(cc2);
        if ~isempty(gaps), gapMax = max(gaps); else, gapMax = 0; end
    end
end

%
function yc = pickNear(colMask, yRef, r0)
%PICKNEAR  在该列掩膜里取"离 yRef 最近的簇"的中心行
    yc = [];
    if ~any(colMask), return; end
    v = colMask(:)';
    e = diff([false, v, false]);
    ss = find(e == 1); ee = find(e == -1) - 1;
    best = []; bestD = inf;
    for k = 1:numel(ss)
        cen = mean(ss(k):ee(k)) + r0 - 1;
        d = abs(cen - yRef);
        if d < bestD, bestD = d; best = cen; end
    end
    yc = best;
end
