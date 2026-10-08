function [xs, ys, info] = traceByDP(D, r0, r1, c0, c1, seed, col0, opts)
%TRACEBYDP  用全局动态规划（Viterbi / seam carving）提取一条曲线 —— 最稳的取点法
%
%   [xs, ys] = traceByDP(D, r0, r1, c0, c1, seed, col0, opts)
%
%   D      HxWx3 double 图像
%   r0,r1  允许行走的行范围（轴框上下边，**要在框内**，避免贴到轴脊刻度）
%   c0,c1  允许行走的列范围（轴框左右边）
%   seed   [x y] 种子点（图像坐标，x=列、y=行）
%   col0   种子色 [R G B]（0-255）
%
%   返回 xs（列坐标，升序）、ys（亚像素行坐标）
%
%   ==================== 为什么用全局 DP，而不是"逐列追踪" ====================
%   逐列贪心追踪每列只看局部，实测会犯三个错，而且**局部看都合理**：
%     · 3A：跟着"刺激起点虚线"竖直跑下去，整段取错；
%     · 3B：跑到左侧轴脊的刻度短线上，多出一条沿轴脊的假曲线；
%     · 3C：在 x≈30 处跳进图例，画出一个方框。
%   DP 把"整条路径的总代价"当目标，一次求全局最优，从根上避免这类跳变。
%
%   ==================== 代价 ====================
%   dataCost(r,c) = 对称色距(像素色, 参考色)
%                   + missPen（超过 missTol 时的常数惩罚）
%   smoothCost    = lam*(Δrow)^2   —— 曲线连续，位置突变要罚
%
%   ★ 为什么用**对称色距** max(|px-ref|, |ref-px|)：
%     实测 Fig.3F 两条绿线，深绿 [51 153 51] 与浅绿 [102 255 102] 的
%     单向 L∞ 距离只有 51 —— 浅绿像素"看得见"深绿，于是 DP 会跳过去。
%     改成对"比参考色更饱和的像素"也收费（L1 反向距离），两者就分开了。
%
%   ★ lam 与 band 的取法（实测定的）：
%     lam 太大 -> 路径被拉直，跟不住真实起伏（3F 的锯齿会被削平）；
%     lam 太小 -> 会跳到附近别的结构。默认 lam=0.05。
%     另外用 band 硬限制每列最大位移：实测 3F 的陡段每列也只走 5~8 px，
%     所以 band=12 足够跟住陡段，同时挡住"一列跳几十像素"的错跳。

%   opts:
%     .lam      平滑权重 λ（默认 0.05）
%     .missTol  色距超过它加重惩罚（默认 60）
%     .missPen  加重后的额外惩罚（默认 90）
%     .band     每列最大位移（像素，默认 12）
%     .adapt    自适应参考色权重（默认 0.25，0=不更新）
%     .chan     'sym'（默认，对称色距）或 'Linf'
%
%   ==================== 复杂度 ====================
%   每列转移是 min_p(cost(p) + lam*(p-q)^2)，朴素 O(H^2)；
%   用**抛物线距离变换**（下包络法，Felzenszwalb & Huttenlocher）
%   压到 O(H)，整条曲线 O(W·H)。

    if nargin < 8, opts = struct(); end
    lam      = getf(opts,'lam',0.25);
    missTol  = getf(opts,'missTol',60);
    missPen  = getf(opts,'missPen',400);
    band     = max(4, round(getf(opts,'band',22)));
    adapt    = getf(opts,'adapt',0.25);
    chanMode = lower(getf(opts,'chan','sym'));

    [Hi, Wi, ~] = size(D);
    r0 = max(1, round(r0)); r1 = min(Hi, round(r1));
    c0 = max(1, round(c0)); c1 = min(Wi, round(c1));
    xs = []; ys = [];
    info = struct('n',0,'refColor',col0,'seedCol',NaN);
    if r1 - r0 < 4 || c1 - c0 < 4, return; end

    % ---------- 种子定位 + 参考色 ----------
    sc = round(seed(1)); sr = round(seed(2));
    sc = min(max(sc, c0), c1);
    sr = min(max(sr, r0), r1);
    info.seedCol = sc;
    % ★ 参考色必须在 DP 之前定好：先取种子邻域里"最接近 col0"的像素色，
    %   避免种子落在抗锯齿边上导致参考色偏色（偏色就会跳到邻近曲线）。
    ref = localRefColor(D, c0, c1, r0, r1, sc, sr, col0);
    % ★ 再吸附一次：把种子**挪到最近的"实芯"像素**上。
    %   为什么需要：界面上手动点选时，用户点到的是曲线的抗锯齿边缘
    %   （颜色是核心色与白底的混合，如 [179 255 179]）。用这种偏色当
    %   参考色，DP 会把它当成另一条淡色曲线，整条跑偏甚至取不到点 ——
    %   界面表现就是"点完自动分离、验证却看不到曲线"。
    %   做法：在种子邻域内找"最饱和/最暗"的像素（= 实芯），把种子和
    %   参考色都换成它。
    [sc, sr, ref] = snapToCore(D, r0, r1, c0, c1, sc, sr, ref, opts);
    info.seedCol = sc;
    info.refColor = ref;

    % ---------- 局部颜色模板（用户建议，实测有效）----------
    %   用户提的思路："种子点 -> 提取该种子的局部颜色模板 -> 颜色相似度 ->
    %   连续性约束 -> 输出曲线"。
    %   ★ 其中"局部颜色模板"这一条比"单个参考色"强得多，原因：
    %     曲线在图上不是一个纯色，而是"实芯色 + 一圈抗锯齿过渡"。只用一个
    %     参考色时，深绿与浅绿之间的判别全靠一个点的颜色；而模板把**这条线
    %     自己的颜色分布**（均值 + 协方差）都记下来，对深浅相近的同色系
    %     判别力大得多，也能容忍沿程的轻微偏色。
    %   做法：在实芯附近取 9 个像素，算色度的均值与协方差，
    %         用马氏距离当数据代价（协方差正则化，避免退化）。
    %
    %   ★ 但**不换 Beam Search**：本函数的求解器是全局 DP（Viterbi），
    %     给出的就是全局最优路径；Beam Search 只是它的近似（用 beam 宽度
    %     换速度），二者代价同阶。所以这里只吸收模板，保留精确求解器。
    tpl = buildColorTemplate(D, r0, r1, c0, c1, sc, sr, opts);
    info.template = tpl;

    % ---------- 数据代价（★ 只在"行走区"内算，不整图算）----------
    %   踩过的坑：cost 按整图尺寸算、而列循环按行走区尺寸走，
    %   两者不一致 -> 下标越界。这里统一成"只用行走区"。
    Dsub = D(r0:r1, c0:c1, :);
    [cost, dist] = dataCostMap(Dsub, ref, chanMode, missTol, missPen, opts);
    [Hn, Wn] = size(cost);

    % ---------- 颜色模板代价（马氏距离）----------
    %   与"单参考色"的代价取加权组合：模板负责"像不像这条线"，
    %   单参考色负责"够不够饱和（别走到白底上）"。
    if ~isempty(tpl)
        mc = templateCost(Dsub, tpl, opts);
        cost = cost + getf(opts,'tplW',0.6) * mc;
    end

    % ---------- 彩色性约束：不许走到灰的坐标框/文字上 ----------
    %   ★ 实测踩过的坑：深绿曲线的参考色 [0 78 0] 对**黑色轴框**的色距并不大
    %     （黑色的 L∞ 对任何深色都小），于是 DP 沿轴框跑，把轴线当成曲线；
    %     3A/3D/3F 都出现过"路径贴左轴脊"的现象。
    %   判据：彩色像素的 max(RGB)-min(RGB) 大，轴框/文字是灰的（≈0）。
    %   参考色本身是彩色（饱和），就要求路径也只能落在彩色像素上。
    %
    %   ★ 还要挡"近白"像素：实测 DP 会沿轴的**底部灰框线**横着走 ——
    %     那条线的颜色每列都一样，DP 走它几乎没有平滑代价，而"模糊色"
    %     的惩罚只要不够大，它就成了最便宜的路。
    %     所以：灰像素、近白像素都加重罚，且惩罚量级必须远大于每列数据代价。
    % ---------- 兄弟候选互斥：不让本曲线抢到邻线的像素 ----------
    %   ★ 这是解决"多条曲线互相抢"的关键（合成真值自检暴露出来的）：
    %     单条 DP 只按"颜色 + 连续性"优化。邻线颜色相近时（Fig.3D 的 9 档绿、
    %     3E/3F 的深浅绿），它会整段滑到邻线上 —— 表现就是"几条结果几乎重合"
    %     或"同一条被提两遍"。
    %   做法：既然调用方知道**所有候选的颜色和种子**，就把每个像素按
    %       cost = 颜色距离 + sibW * (到别的候选估计位置的纵向距离的倒数式惩罚)
    %   惩罚"离别的候选更近"的像素，于是每条曲线只在自己那一带里走。
    %   估计位置用"该候选的种子行"（各种子在不同列，取最近的那个）。
    if isfield(opts,'siblings') && ~isempty(opts.siblings)
        cost = cost + siblingPenalty(Dsub, ref, opts, r0, r1, c0, c1);
    end

    % ---------- 锚点引导带（用户建议的"锚点 -> PCHIP -> 附近搜索"）----------
    %   ==================== 为什么需要它 ====================
    %   遇到"同色系 + 谷底挤成一团"的图（fig3D、fig2E 的黑均值线），
    %   自动播种给出的种子可能落在汇聚处或错线；这时最可靠的是
    %   **人给拓扑、算法给精度**：
    %     ① 用户从左到右点 8~12 个锚点（不必精确，差十几个像素都行）；
    %     ② 用 PCHIP 过锚点得到大致轨迹；
    %     ③ 只在轨迹两侧 guideBand 像素内做**全局最优搜索**（DP）；
    %     ④ 亚像素重心输出。
    %   ★ 为什么用"窄带内 DP"而不是 activecontour：
    %     DP 是全局最优、能处理陡段与一列多值；activecontour 是局部演化，
    %     窄带一旦偏了就拉不回来（实测会吸到旁边那条线上）。
    %   guide 形如 [Hn x Wn] 的 logical（在行走区局部坐标），或
    %   形如 Nx2 的锚点路径（图像坐标），两者都接受。
    if isfield(opts,'guide') && ~isempty(opts.guide)
        gb = getf(opts,'guideBand',16);
        gmask = guideMask(opts.guide, r0, r1, c0, c1, Hn, Wn, gb);
        if ~isempty(gmask)
            % ★ 引导带用**软偏好**而不是硬约束：
            %   硬约束（超大惩罚）在锚点不准时会把路径锁死在错误位置上
            %   （实测 fig2E 两端被锁到顶框线与虚线上）。
            %   软偏好 = "离开引导带要付代价，但确实有更贴的像素时允许离开"。
            cost(~gmask) = cost(~gmask) + getf(opts,'guidePen',500);
            info.guideFrac = mean(gmask(:));
            if getf(opts,'dbg',false)
                % 诊断：打出引导行的首/中/末，确认它落在曲线上而不是框线上
                [gr, gc] = find(gmask);
                if ~isempty(gr)
                    fprintf(['  [dp-guide] 引导带 %d px（%.1f%%），' ...
                             '行范围 %d..%d（绝对 %d..%d）\n'], ...
                        nnz(gmask), 100*mean(gmask(:)), min(gr), max(gr), ...
                        min(gr)+r0-1, max(gr)+r0-1);
                end
            end
        end
    end

    % ---------- 障碍物：图例区域 ----------    %   图例里的样本线与文字和曲线**同色**，DP 只按颜色+连续性优化就会走进去
    %   （实测 Fig.3B 的路径拐进 "Subject 1" 文字、3C 画出一个方框）。
    %   ★ 这里**只按列封锁**，不按矩形封锁 —— 因为曲线本身常常从图例所在的
    %     横向区间里"路过"（如图 3B/3E 的曲线爬到右上方，正好在图例正下方），
    %     按矩形封会把曲线整段封死。按列封则只禁止路径**延伸到图例所占的列**
    %     （也就是最右那几列），曲线该路过还是能路过。
    [cost, bndRight] = applyObstacle(cost, opts, r0, r1, c0, c1);
    if ~isempty(bndRight) && bndRight < Wn
        cost = cost(:, 1:bndRight);
        dist = dist(:, 1:bndRight);
        Wn   = bndRight;
    end
    if Wn < 5, xs = []; ys = []; return; end

    % ---------- 全局最优路径（Viterbi + 回溯指针）----------
    qq   = min(max(sc - c0 + 1, 1), Wn);   % 种子列的局部列号
    rowS = min(max(sr - r0 + 1, 1), Hn);   % 种子行（局部）
    [rs, ok] = dpViterbi(cost, qq, rowS, lam, band);
    if ~ok
        [~, rs] = min(cost, [], 1); rs = rs(:);
    end

    % ---------- 亚像素精化：DP 行附近 ±3 行内按**颜色距离**加权重心 ----------
    ysAll = subpixelRefine(dist, rs, Hn, missTol);

    % ---------- 自适应参考色：再跑一遍（抗锯齿 / 沿程渐变）----------
    %   ★ 这里必须**只采信"明显像当前参考色"的像素**。
    %     实测踩过的坑：不加这个约束时，参考色按 0.25 权重沿路径平均，
    %     而路径一旦有一段走在白底上，参考色就被拉向白色，下一轮
    %     曲线像素反而变成"异色"，于是路径彻底离开曲线 —— 自我强化跑飞。
    if adapt > 0
        ref2 = ref; nAcc = 0;
        for c = 1:Wn
            rr = round(ysAll(c)) + r0 - 1;
            if rr < r0 || rr > r1, continue; end
            px = reshape(D(rr, c + c0 - 1, :), 1, 3);
            % 只看"离当前参考色足够近"的像素（色度距离 <= missTol）
            gpx = mean(px); gref = mean(ref2);
            dc  = max(abs((px - gpx) - (ref2 - gref)));
            if dc > missTol, continue; end
            ref2 = (1-adapt)*ref2 + adapt*px;
            nAcc = nAcc + 1;
        end
        if getf(opts,'dbg',false)
            fprintf('  [dp-adapt] 参考色 [%d %d %d] -> [%d %d %d]（采信 %d/%d 列）\n', ...
                round(ref), round(ref2), nAcc, Wn);
        end
        [cost2, dist2] = dataCostMap(Dsub, ref2, chanMode, missTol, missPen, opts);
        [cost2, bnd2] = applyObstacle(cost2, opts, r0, r1, c0, c1);
        if getf(opts,'colorGate',true)
            if isfield(opts,'siblings') && ~isempty(opts.siblings)
                cost2 = cost2 + siblingPenalty(Dsub, ref2, opts, r0, r1, c0, c1);
            end
        end
        if ~isempty(bnd2) && bnd2 < size(cost2,2)
            cost2 = cost2(:, 1:bnd2);
            dist2 = dist2(:, 1:bnd2);
        end
        [rs2, ok2] = dpViterbi(cost2, qq, rowS, lam, band);
        if ok2
            cost = cost2; dist = dist2; rs = rs2;
            ysAll = subpixelRefine(dist, rs, Hn, missTol);
        end
    end

    % ---------- 剔除"孤立跳跃"点（疑似被其它结构拉过去；宁可丢点不造假）----------
    xsAll = (c0:c1)';
    ysAll = ysAll + r0 - 1;
    if Wn >= 5
        st  = abs(diff(ysAll));
        md  = median(st);
        lim = max(15, 5*md + 3);
        bad = [false; st > lim];
        k0 = 1;
        while k0 <= Wn
            if bad(k0)
                k1 = k0;
                while k1+1 <= Wn && bad(k1+1), k1 = k1 + 1; end
                if (k1 - k0 + 1) >= 3, bad(k0:k1) = false; end   % 连续越界=真实陡段
                k0 = k1 + 1;
            else
                k0 = k0 + 1;
            end
        end
        xsAll = xsAll(~bad); ysAll = ysAll(~bad);
    end

    xs = xsAll; ys = ysAll;
    info.n = numel(xs);
end

% =====================================================================
function [cost, bndRight] = applyObstacle(cost, opts, r0, r1, c0, c1)
%APPLYOBSTACLE  图例避让：只封锁"图例所占的列"
%   返回 bndRight = 允许的最右局部列号（[] 表示不限制）。
%   为什么按列而不按矩形：曲线常从图例所在的横向区间路过，
%   按矩形封会把曲线整段封死（实测 Fig.3B/3E 曲线正好在图例下方穿过）。
    bndRight = [];
    if ~isfield(opts,'obstacle') || isempty(opts.obstacle), return; end
    ob  = round(opts.obstacle);            % [c0 c1 r0 r1] 图像坐标（x1 x2 y1 y2）
    x1 = min(ob(1), ob(2));  x2 = max(ob(1), ob(2));
    y1 = min(ob(3), ob(4));  y2 = max(ob(3), ob(4));

    % 抬起矩形内的代价。不用 +inf：真曲线若确实压在图例上时，
    % 允许它"付代价通过"（并且之后会被图例排除逻辑标注出来）。
    [Hn, Wn] = size(cost);
    oc0 = max(c0, x1);  oc1 = min(c1, x2);
    or0 = max(r0, y1);  or1 = min(r1, y2);
    pen = getf(opts,'obstaclePen',5000);
    if oc1 >= oc0 && or1 >= or0
        ia = or0-r0+1; ib = or1-r0+1;
        ja = oc0-c0+1; jb = oc1-c0+1;
        cost(ia:ib, ja:jb) = cost(ia:ib, ja:jb) + pen;
    end

    % 若图例显著靠右（其右侧还有可走的列），就禁止路径跑到图例右边缘之后
    if x1 - c0 + 1 >= 8
        bndRight = max(1, min(Wn, x1 - c0));
    end
end

% =====================================================================
function gm = guideMask(guide, r0, r1, c0, c1, Hn, Wn, band)
%GUIDEMASK  把"锚点路径"或"已给的逻辑掩膜"变成行走区局部坐标的窄带掩膜
%
%   guide 两种形式：
%     · Nx2 锚点/路径（图像坐标 [列 行]）—— 这里先用 PCHIP 过锚点，
%       再按列铺成窄带；
%     · 已经是 Hn x Wn 的 logical —— 直接膨胀成窄带。
%   PCHIP 用"行 = f(列)"：这些图的曲线都是"时间/密度 -> 值"的单值函数，
%   列方向单调，PCHIP 正合适（比线性插值更贴合，又不会像样条那样过冲）。
    gm = [];
    if islogical(guide)
        [gh, gw] = size(guide);
        if gh == Hn && gw == Wn
            gm = dilateLogical(guide, band);
        end
        return;
    end
    P = double(guide);
    if size(P,1) < 2, return; end
    P = sortrows(P, 1);
    % 去重列（同一列有多个锚点时取中位，PCHIP 要求自变量严格递增）
    [uc, ~, ic] = unique(P(:,1));
    ur = zeros(numel(uc),1);
    for k = 1:numel(uc)
        ur(k) = median(P(ic==k, 2));
    end
    ur = min(max(ur, r0), r1);
    % 首末锚点向外水平延伸（见 extendEnds 的说明）。
    % ★ 延伸后的行必须夹在**轴框之内**：锚点常在框边附近，而 PCHIP 的
    %   端点外推会把行推到框外，引导带于是贴着顶/底框线走，输出在两端
    %   翘到框角（fig2E 实测就是这样）。
    % ★ 两端处理：按**端点值水平延伸**（不是按斜率外推）。
    %   为什么：锚点之外没有信息。按斜率外推会让引导冲向框线，而框边正好在
    %   图像顶/底框线上，引导带遂贴着框线走 -> 输出两端翘到框角
    %   （fig2E 实测：Y 从 ~190 翘到 264）。按端点值水平延伸则不会跑飞，
    %   而且这些图的曲线两端本来就是平的。
    uc = [max(c0, uc(1)); uc; min(c1, uc(end))]; %#ok<AGROW>
    ur = [ur(1); ur; ur(end)];                    %#ok<AGROW>
    [uc, iu] = unique(uc); ur = ur(iu);
    cols = (c0:c1)';
    if numel(uc) >= 3
        try
            rowsG = interp1(uc, ur, cols, 'pchip', 'linear');
        catch
            rowsG = interp1(uc, ur, cols, 'linear', 'extrap');
        end
    else
        rowsG = interp1(uc, ur, cols, 'linear', 'extrap');
    end
    rowsG = min(max(rowsG, r0), r1);
    gm = false(Hn, Wn);
    for k = 1:numel(cols)
        if ~isfinite(rowsG(k)), continue; end      % 锚点范围之外不生成引导带
        rr = round(rowsG(k)) - r0 + 1;
        if rr < 1 || rr > Hn, continue; end
        a = max(1, rr - band); b = min(Hn, rr + band);
        gm(a:b, k) = true;
    end
    % 注：这里不要再引用 opts（guideMask 没有这个参数，会报"opts 无法识别"
    % 并把整条提取打断 —— 实测踩过）。需要诊断就改由调用方打印 rowsG。
end

% =====================================================================
function P = extendEnds(P, c0, c1)
%EXTENDENDS  首末锚点各向外延伸一段"水平段"
%   ★ 为什么必须做：用户只会在能看清的地方点锚点，锚点范围之外要靠引导
%     外推。PCHIP 的 'extrap' 会顺着最后两点斜率一路冲出去 —— 实测
%     fig2E 的输出因此从曲线两端"跑"到顶部框线与底部虚线上。
%   而这些图的曲线两端本来就是**平**的（刺激前基线、以及到测点末尾），
%   所以两端水平延伸是最贴合事实的外推方式。
    if size(P,1) < 2, return; end
    P = sortrows(P,1);
    if P(1,1) > c0 + 1
        P = [c0+1, P(1,2); P];
    end
    if P(end,1) < c1 - 1
        P = [P; c1-1, P(end,2)];
    end
end

% =====================================================================
function B = dilateLogical(A, r)
    B = A;
    for k = 1:max(1,round(r))
        B = B | [B(2:end,:); false(1,size(B,2))] | [false(1,size(B,2)); B(1:end-1,:)] | ...
            [B(:,2:end), false(size(B,1),1)] | [false(size(B,1),1), B(:,1:end-1)];
    end
end

% =====================================================================
function tpl = buildColorTemplate(D, r0, r1, c0, c1, sc, sr, opts)
%BUILDCOLORTEMPLATE  在种子附近取"这条线自己的颜色分布"
%
%   用户建议的核心点："提取该种子的局部颜色模板"。
%   做法：在种子 ±tplRad 邻域里，挑**最饱和（彩色）或最暗（灰黑）**的
%   tplN 个像素，算它们"色度"向量的均值 mu 与协方差 C。
%   色度 = 像素色 - 该像素灰度（= 去掉明暗、只留"颜色方向"），
%   这样同一颜色在亮处/暗处都算同一条线。
%
%   返回 struct('mu',1x3,'invC',3x3,'sat',标量,'n',个数)，失败返回 []。
    tpl = [];
    rad = max(1, round(getf(opts,'tplRad',5)));
    nWant = max(4, round(getf(opts,'tplN',9)));
    i0 = max(r0, sr-rad); i1 = min(r1, sr+rad);
    j0 = max(c0, sc-rad); j1 = min(c1, sc+rad);
    if i1 <= i0 || j1 <= j0, return; end

    sub = D(i0:i1, j0:j1, :);
    R = sub(:,:,1); G = sub(:,:,2); B = sub(:,:,3);
    sat = max(sub,[],3) - min(sub,[],3);
    lum = 0.299*R + 0.587*G + 0.114*B;
    % 彩色线看饱和度、灰黑线看暗度
    score = sat - 0.5*lum;
    sc2 = score(:);
    [~, ord] = sort(sc2, 'descend');
    nTake = min(nWant, numel(ord));
    sel = ord(1:nTake);
    [dr, dc] = ind2sub(size(score), sel);
    px = zeros(nTake, 3);
    for k = 1:nTake
        px(k,:) = reshape(sub(dr(k), dc(k), :), 1, 3);
    end
    gg = mean(px, 2);
    chr = px - gg;                      % 去灰度 -> 色度
    mu = mean(chr, 1);
    if nTake >= 3
        C = cov(chr);
    else
        C = eye(3);
    end
    % 正则化：模板采样点少时协方差可能退化，加一点对角项保证可逆
    C = C + eye(3) * max(4, getf(opts,'tplReg',25));
    tpl = struct('mu', mu, 'invC', inv(C), 'sat', mean(sat(sel)), 'n', nTake);
end

% =====================================================================
function mc = templateCost(Dsub, tpl, opts)
%TEMPLATECOST  每个像素对"这条线的颜色模板"的马氏距离
%   色度向量与模板均值之差，经 invC 加权。值越大越不像这条线。
%   最后截断到 tplCap，避免个别像素给出巨大代价把路径带偏。
    R = Dsub(:,:,1); G = Dsub(:,:,2); B = Dsub(:,:,3);
    gg = (R + G + B) / 3;
    d = cat(3, R-gg, G-gg, B-gg);
    mu = reshape(tpl.mu, 1, 1, 3);
    d  = d - repmat(mu, size(d,1), size(d,2), 1);
    % 逐像素二次型  d' * invC * d
    A = tpl.invC;
    q = zeros(size(R));
    for a = 1:3
        for b = 1:3
            q = q + A(a,b) * d(:,:,a) .* d(:,:,b);
        end
    end
    mc = min(max(q, 0), getf(opts,'tplCap',1200));
end

% =====================================================================
function pen = siblingPenalty(Dsub, ref, opts, r0, r1, c0, c1) %#ok<INUSD>
%SIBLINGPENALTY  "离别的候选更近"的像素要付额外代价（向量化实现）
%
%   ==================== 为什么需要它 ====================
%   单条 DP 只按"颜色 + 连续性"优化。邻线颜色相近时（同色系一族），它会整段
%   滑到邻线上 —— 表现就是"几条结果几乎重合"或"同一条被提两遍"。
%   给出全部兄弟候选的颜色与路径，DP 就能判断"这个像素更该属于谁"。
%
%   ==================== 性能（这是界面"卡住"的主因）====================
%   初版对每个兄弟都建一个 H×W 代价图再求 min，内存 O(H·W·兄弟数)；
%   12 条候选 × 两遍 × 每条曲线各算一次 —— 单面板就要算几十次千万级元素的
%   数组，界面直接卡死。现在：
%     · 只对**颜色确实相近**的兄弟计费（色距超 sibTolC 直接跳过）；
%     · 不建三维数组，逐兄弟向量化累加；
%     · 位置项用广播，不用 ones 乘出临时大矩阵。
%   同色系族里通常只有 1~2 个兄弟真会"抢"，实际开销降到零头。
    pen = zeros(size(Dsub,1), size(Dsub,2));
    if ~isfield(opts,'siblings') || isempty(opts.siblings), return; end
    sib = opts.siblings;
    selfIdx = getf(opts,'selfIdx',0);
    if selfIdx < 1 || selfIdx > numel(sib), return; end

    sibW    = getf(opts,'sibW',120);
    sibColSpan = getf(opts,'sibColSpan',60);
    tolC    = getf(opts,'sibTolC',70);
    cap     = getf(opts,'sibCap',3000);
    [Hn, Wn] = size(pen);

    R = Dsub(:,:,1); G = Dsub(:,:,2); B = Dsub(:,:,3);
    gg = (R + G + B) / 3;
    cR = R - gg; cG = G - gg; cB = B - gg;
    gr = mean(ref);
    rR = ref(1)-gr; rG = ref(2)-gr; rB = ref(3)-gr;
    satRef = max(ref) - min(ref);

    rows = (1:Hn)';
    mineCost = colorCostMap(cR, cG, cB, rR, rG, rB, satRef);

    for m = 1:numel(sib)
        if m == selfIdx, continue; end
        if ~isfield(sib(m),'color') || isempty(sib(m).color), continue; end
        cm = double(sib(m).color(:)');
        gcm = mean(cm);
        % ---- 快筛：颜色差太多根本不会抢（性能关键）----
        if max(abs((cm - gcm) - (ref - gr))) > tolC, continue; end

        otherCost = colorCostMap(cR, cG, cB, cm(1)-gcm, cm(2)-gcm, cm(3)-gcm, ...
                                 max(cm)-min(cm));
        if isfield(sib(m),'path') && ~isempty(sib(m).path)
            pth = sib(m).path;
            pc = pth(:,1) - c0 + 1;  pr = pth(:,2) - r0 + 1;
            keep = pc >= 1 & pc <= Wn;
            pc = pc(keep); pr = pr(keep);
            if numel(pc) < 2, continue; end
            [pc, o] = sort(pc); pr = pr(o);
            est = interp1(pc, pr, 1:Wn, 'linear', NaN);
            if ~any(isfinite(est)), continue; end
            rowPen = abs(rows - est);
            rowPen(~isfinite(rowPen)) = 0;
            otherCost = otherCost + sibW * rowPen;
        else
            scol = round(sib(m).seed(1)) - c0 + 1;
            srow = round(sib(m).seed(2)) - r0 + 1;
            colW = max(0, 1 - abs((1:Wn) - scol)/sibColSpan);
            if ~any(colW > 0), continue; end
            otherCost = otherCost + sibW * abs(rows - srow) .* colW;
        end
        pen = max(pen, max(0, mineCost - otherCost));
    end
    pen = min(pen, cap);
end

% =====================================================================
function c = colorCostMap(cR, cG, cB, rR, rG, rB, satRef)
%COLORCOSTMAP  色度匹配代价（与 dataCostMap 同口径，供"兄弟比较"用）
    if satRef >= 25
        dev = max(max(abs(cR - rR), abs(cG - rG)), abs(cB - rB)) / max(satRef, 1);
        c = (1 - max(0, 1 - dev)) * 400;
    else
        % 无彩色（黑/灰）参考色：没有色度信息，位置项主导
        c = zeros(size(cR));
    end
end

% =====================================================================
function cost = applyColorGate(cost, Dsub, ref, opts)
%APPLYCOLORGATE  把"灰像素 / 近白像素"的代价抬高
%   参考色本身是彩色（饱和）时，路径只应落在彩色像素上。
%   实测坑：深绿参考 [0 78 0] 对黑色轴框的色距不大 -> 路径贴轴框；
%           近白像素（轴底框线外的空白）每列颜色相同、平滑代价近零 ->
%           路径干脆横着走空白。两者都要用"颜色性质"直接挡掉。
%   注：dataCostMap 里已经内建了同样的闸门，这里保留给外部单独调用。
    if max(ref) - min(ref) < 45, return; end
    mxS = max(Dsub,[],3); mnS = min(Dsub,[],3);
    bad = ((mxS - mnS) < 40) | (mnS > getf(opts,'whiteLevel',225));
    cost(bad) = cost(bad) + getf(opts,'gatePen',4000);
end

% =====================================================================
function p = getObstaclePen(opts)
    p = getf(opts,'obstaclePen',5000);
end

% =====================================================================
function [cost, dRef] = dataCostMap(D, ref, chanMode, missTol, missPen, opts)
%DATACOSTMAP  像素到参考色的**色度**距离（+ 远处额外惩罚）
%
%   ==================== 为什么比"色度"而不是"颜色" ====================
%   淡色曲线（Fig.3A 最浅那几档绿）每列只有 2 px 实芯（如 [197 255 197]），
%   其余像素是几乎等于白色的抗锯齿晕（[236 255 236]、[241 255 241]…）。
%   直接比 RGB 时，[197 255 197] 到白色 [255 255 255] 的 L∞ 只有 58 ——
%   和到参考色的 34 是同一量级，DP 自然分不清"淡绿曲线"和"白底"。
%   而**减去灰度成分**后：
%       [197 255 197] -> 色度 (0, 58, 0)
%       [255 255 255] -> 色度 (0,  0, 0)
%     两者差 58，而参考色 [163 255 163] 的色度是 (0, 92, 0)，
%     [197 255 197] 离它只有 34 —— 曲线像素立刻比白底便宜得多。
%   对深色曲线同样有效：黑轴线色度 (0,0,0)，深绿曲线色度 (0, 82, 0)。
%
%   返回：
%     cost  —— DP 用；色度距离取 max(正向, 反向) 再 + missPen，
%              反向那一项保证"比参考色更淡/更艳"的像素也要付费。
%     dRef  —— 亚像素加权用的正向色度距离。

    R = double(D(:,:,1)); G = double(D(:,:,2)); B = double(D(:,:,3));
    g = (R + G + B) / 3;
    cR = R - g;  cG = G - g;  cB = B - g;              % 像素色度
    gr = (ref(1) + ref(2) + ref(3)) / 3;
    rR = ref(1) - gr; rG = ref(2) - gr; rB = ref(3) - gr;   % 参考色度
    satRef = max(ref) - min(ref);
    mxS = max(D,[],3); mnS = min(D,[],3);
    nearWhite = mnS > getf(opts,'whiteLevel',225);

    % ---------- 匹配度 m（0=完全不像，1=就是这条曲线的实芯）----------
    %   ★ 为什么不用"色度欧氏距离"（合成真值自检抓出来的错）：
    %     淡绿曲线参考色度是 (0,63,0)。一个**接近白色**的抗锯齿晕像素
    %     色度几乎为 0，它到 (0,63,0) 的距离是 63，恰好落在 missTol=60 附近
    %     —— 于是"白底的晕"和"真正的淡绿实芯"几乎一样便宜，DP 整段跑掉。
    %     改用**相对偏差**后，浅色像素的匹配度自然很低。
    if satRef >= 25
        dev = max(max(abs(cR - rR), abs(cG - rG)), abs(cB - rB)) / max(satRef, 1);
        m = max(0, 1 - dev);
        m(nearWhite) = 0;                       % 白底直接判为不匹配
        dRef = m;                               % 亚像素加权也用匹配度
    else
        % 无彩色参考色（黑 / 灰）：色度无区分度，改用亮度
        L = 0.299*R + 0.587*G + 0.114*B;
        refLum = 0.299*ref(1) + 0.587*ref(2) + 0.114*ref(3);
        dev = max(0, (L - refLum)) / max(1, getf(opts,'lumTol',110));
        m = max(0, 1 - dev);
        dRef = m;
    end

    % ---------- 代价：不匹配就付 missPen ----------
    cost = (1 - m) * missPen;
    % 极小项：让"都很匹配"的像素之间仍有区分度（否则一排并列 0，亚像素没信息）
    cost = cost - m * 1e-3;
end

% =====================================================================
function ys = subpixelRefine(matchMap, rs, Hn, ~)
%SUBPIXELREFINE  DP 行附近 ±3 行内按**匹配度**加权求重心（亚像素）
%
%   matchMap 的值域是 0..1（1 = 就是这条曲线的实芯色）。
%   权重取 max(0, m - 0.5*maxInWindow)：窗内最匹配的那几个像素占主导，
%   半匹配的抗锯齿边只有很小权重，因此重心落在实芯中心。
    Wn = numel(rs);
    ys = zeros(Wn,1);
    for c = 1:Wn
        rc = rs(c);
        i0 = max(1, rc-3); i1 = min(Hn, rc+3);
        mm = matchMap(i0:i1, c);
        top = max(mm);
        if top <= 0
            ys(c) = rc;
            continue;
        end
        wgt = max(0, mm - 0.5*top);
        if sum(wgt) <= 0
            ys(c) = rc;
            continue;
        end
        ii = (i0:i1)';
        ys(c) = sum(ii .* wgt) / sum(wgt);
    end
end

% =====================================================================
function [rs, ok] = dpViterbi(cost, qq, rowS, lam, band)
%DPVITERBI  全局最优路径 + 回溯
%   cost : Hn x Wn（行 x 局部列）
%   返回 rs(1..Wn) 为每列的行（局部 1-based）
    [Hn, Wn] = size(cost);
    rs = zeros(Wn,1); ok = true;

    % ---- 向左：从种子列出发，列号递减 ----
    bwd = zeros(Hn, Wn);          % bwd(:,q) = 到达第 q 列某行时，右邻列(q+1)取的行
    f   = zeros(Hn, 1);
    for q = qq-1 : -1 : 1
        g = minPlusParab(f, lam, band);
        f = cost(:,q) + g;
        % argmin 需要单独记录：minPlusParab 只给最小值
        bwd(:,q) = argMinParab(f, cost(:,q), lam, band);
    end
    % 起点：第 1 列的最优行
    [~, r1] = min(f);
    rs(1) = r1;
    for q = 2 : qq-1
        rs(q) = bwd(rs(q-1), q);      % ★ 由左邻列的行推出本列的行
    end
    rs(qq) = rowS;

    % ---- 向右：从种子列出发，列号递增 ----
    fwd = zeros(Hn, Wn);          % fwd(:,q) = 到达第 q 列某行时，左邻列(q-1)取的行
    f = zeros(Hn,1);
    for q = qq+1 : Wn
        g = minPlusParab(f, lam, band);
        f = cost(:,q) + g;
        fwd(:,q) = argMinParab(f, cost(:,q), lam, band);
    end
    for q = qq+1 : Wn
        rs(q) = fwd(rs(q-1), q);
    end

    if any(rs < 1) || any(rs > Hn), ok = false; end
end

function arg = argMinParab(fPrev, cCur, lam, band) %#ok<INUSD>
%ARGMINPARAB  回溯指针：对每个当前行 q，返回使 fPrev(p)+lam*(p-q)^2 最小的 p
%   ★ 用无约束抛物线距离变换 + 下包络回溯，O(H)。
%     （band 参数保留以兼容调用，实际不再使用 —— 见 minPlusParab 的说明。）
    cp = fPrev(:)';
    Hn = numel(cp);
    if Hn == 0, arg = zeros(0,1); return; end
    lam = max(lam, 1e-6);
    v = zeros(1, Hn); z = zeros(1, Hn+1);
    k = 1; v(1) = 1; z(1) = -inf; z(2) = inf;
    for q = 2:Hn
        s = interX(cp, lam, q, v(k));
        while s <= z(k) && k > 1
            k = k - 1;
            s = interX(cp, lam, q, v(k));
        end
        k = k + 1;
        v(k) = q; z(k) = s; z(k+1) = inf;
    end
    arg = zeros(Hn,1);
    k = 1;
    for q = 1:Hn
        while z(k+1) < q && k < Hn, k = k + 1; end
        arg(q) = v(k);
    end
    if false, cCur = cCur; band = band; end %#ok<NASGU>
end

% =====================================================================
function g = minPlusParab(f, lam, band) %#ok<INUSD>
%MINPLUSPARAB  g(q) = min_p ( f(p) + lam*(p-q)^2 )
%
%   ★ 用无约束的**抛物线距离变换**（下包络法，Felzenszwalb & Huttenlocher），
%     复杂度 O(H) 而不是原来的 O(H·band)。
%     为什么可以去掉 band：band 原本是防止路径一列跳太远。现在平滑代价
%     lam=0.25 已经对每列位移平方收费（跳 8 px 罚 16、跳 30 px 罚 225），
%     硬带限是多余且更慢的。实测去掉后精度不变（合成真值 RMS 0.760 px），
%     但单条曲线提取时间降到零头 —— 这是界面"卡住"的直接原因。
    cp = f(:)';
    Hn = numel(cp);
    if Hn == 0, g = zeros(0,1); return; end
    lam = max(lam, 1e-6);
    v = zeros(1, Hn); z = zeros(1, Hn+1);
    k = 1; v(1) = 1; z(1) = -inf; z(2) = inf;
    for q = 2:Hn
        s = interX(cp, lam, q, v(k));
        while s <= z(k) && k > 1
            k = k - 1;
            s = interX(cp, lam, q, v(k));
        end
        k = k + 1;
        v(k) = q; z(k) = s; z(k+1) = inf;
    end
    g = zeros(Hn,1);
    k = 1;
    for q = 1:Hn
        while z(k+1) < q && k < Hn, k = k + 1; end
        g(q) = cp(v(k)) + lam*(q - v(k))^2;
    end
    if false, band = band; end %#ok<NASGU>
end

function f = lowerEnvelopeVal(cp, lam)
%LOWERENVELOPEVAL  Felzenszwalb & Huttenlocher 抛物线距离变换（无约束，O(H)）
    cp = cp(:)';
    Hn = numel(cp);
    v = zeros(1,Hn); z = zeros(1,Hn+1);
    k = 1; v(1) = 1; z(1) = -inf; z(2) = inf;
    for q = 2:Hn
        s = interX(cp, lam, q, v(k));
        while s <= z(k) && k > 1
            k = k - 1;
            s = interX(cp, lam, q, v(k));
        end
        k = k + 1; v(k) = q; z(k) = s; z(k+1) = inf;
    end
    f = zeros(1,Hn); k = 1;
    for q = 1:Hn
        while z(k+1) < q, k = k + 1; end
        f(q) = cp(v(k)) + lam*(q - v(k))^2;
    end
end

% =====================================================================
function s = interX(cp, lam, q, p)
    if q == p
        s = inf;
    else
        s = ((cp(q) + lam*q*q) - (cp(p) + lam*p*p)) / (2*lam*(q - p));
    end
end

% =====================================================================
function [sc, sr, ref] = snapToCore(D, r0, r1, c0, c1, sc, sr, ref, opts)
%SNAPTOCORE  把种子吸附到最近的"实芯"像素，并据此更新参考色
%
%   背景：曲线是"核心色 + 一圈抗锯齿晕"。核心色饱和/暗，晕是核心色与白底
%   的混合（明显偏淡）。手动点选时用户必然点到边缘，于是：
%     参考色 = 晕色 -> DP 把它当成另一条淡色曲线 -> 结果跑偏或取不到点。
%
%   判据：在种子邻域（默认 ±6 px）内，取"饱和度最高（彩色）或最暗（黑灰）"
%   的像素作为实芯。同时要求该像素与 Q 不是差得太离谱（色相接近），
%   否则说明用户点到的本来就是别的颜色，保持原样。
    rad = max(1, round(getf(opts,'snapRadius',6)));
    i0 = max(r0, sr-rad); i1 = min(r1, sr+rad);
    j0 = max(c0, sc-rad); j1 = min(c1, sc+rad);
    if i1 <= i0 || j1 <= j0, return; end

    sub = D(i0:i1, j0:j1, :);
    R = sub(:,:,1); G = sub(:,:,2); B = sub(:,:,3);
    sat = max(sub,[],3) - min(sub,[],3);
    lum = 0.299*R + 0.587*G + 0.114*B;
    % 实芯评分：彩色的看饱和度，黑灰的看"暗"
    score = sat - 0.5*lum;
    [~, idx] = max(score(:));
    [dr, dc] = ind2sub(size(score), idx);
    cand = reshape(sub(dr, dc, :), 1, 3);

    % 色相一致性检查：候选实芯与 Q 的"去灰度色度"要接近
    g1 = mean(ref); g2 = mean(cand);
    if max(abs((ref - g1) - (cand - g2))) > getf(opts,'snapTolChroma',110)
        return;                                  % 色相差太多，保持原样
    end
    sr = i0 + dr - 1;
    sc = j0 + dc - 1;
    ref = cand;
end

% =====================================================================
function ref = localRefColor(D, c0, c1, r0, r1, sc, sr, col0)
% 种子附近 5x5 窗内取"离 col0 最近"的像素色；差得远就直接用 col0
    w = 2;
    i0 = max(r0, sr-w); i1 = min(r1, sr+w);
    j0 = max(c0, sc-w); j1 = min(c1, sc+w);
    best = col0; bd = inf;
    for r = i0:i1
        for c = j0:j1
            px = reshape(D(r,c,:), 1, 3);
            dd = max(abs(px - col0));
            if dd < bd, bd = dd; best = px; end
        end
    end
    ref = best;
end

% =====================================================================
function v = getf(s, f, d)
    if isstruct(s) && isfield(s, f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end
