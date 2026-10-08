function [mk, stat] = detectMarkers(mask, colRange, rowRange, opts)
%DETECTMARKERS  检测数据点标记（圆点）的中心 —— 交叉验证用的"真值"。
%
%   ★ 为什么标记点重要：
%   标记点比曲线好认得多（一个圆点在十几列里都很粗，曲线每列只有 2~4 px），
%   而且它**独立于拟合曲线**：曲线是穿过标记点的拟合线。所以标记点可以
%   当作真值，用来交叉验证曲线提取得对不对。
%
%   ================== v2：改用 imfindcircles ==================
%   v1 的判据是"该列像素数 >= minThick 且横向宽度在 6~24 列之间"，
%   用横线+圆点的图例样本和误差棒来区分。它有两个克服不了的毛病：
%     · 误差棒顶端、图例样本、文字笔画都满足宽度判据，误检多；
%     · 圆形程度完全没用上 —— 而"是不是圆"才是标记点最强的特征。
%   本机已确认有 Image Processing Toolbox，于是 v2 直接用 imfindcircles
%   做圆检测（它内部是圆霍夫变换 + 边缘梯度），并保留 v1 作为无 IPT 时的回退。
%
%   用法（不变）:
%     [mk, stat] = detectMarkers(mask, [c0 c1], [r0 r1], opts)
%     opts.I        灰度或彩色图（**给了才启用圆检测**；不给则走 v1）
%     opts.minR/maxR  圆半径范围（默认按轴框尺寸自适应）
%     opts.sens     圆检测灵敏度 0~1（默认 0.88）
%     opts.excludeRect  要排除的区域（图例框）[x0 y0 x1 y1]
%
%   返回 mk：N×2，[列, 行]（原图坐标）；stat 里带 method 说明走的哪条路。

    if nargin < 4, opts = struct(); end
    if ~isfield(opts,'minThick'), opts.minThick = 10; end
    if ~isfield(opts,'minWidth'), opts.minWidth = 6;  end
    if ~isfield(opts,'maxWidth'), opts.maxWidth = 24; end
    if ~isfield(opts,'excludeRect'), opts.excludeRect = []; end
    if ~isfield(opts,'I'), opts.I = []; end
    % 灵敏度按实测定在 0.85：0.90 会把曲线的陡段也当成圆
    % （实测 Subject1 在 X≈3.08 处多报 Y=446 与 526 两个假标记）。
    if ~isfield(opts,'sens'), opts.sens = 0.85; end

    c0 = colRange(1); c1 = colRange(2);
    r0 = rowRange(1); r1 = rowRange(2);
    ms = mask(r0:r1, c0:c1);
    if ~isempty(opts.excludeRect)
        ex = round(opts.excludeRect);
        cc = (c0:c1) >= ex(1) & (c0:c1) <= ex(3);
        rr = (r0:r1) >= ex(2) & (r0:r1) <= ex(4);
        ms(rr, cc) = false;
    end

    mk = zeros(0,2);
    stat = struct('nCols',0,'nRound',0,'nBar',0,'method','v1-width');

    % ---------------- v2：圆检测 ----------------
    if ~isempty(opts.I) && exist('imfindcircles','file') && exist('imgaussfilt','file')
        try
            D = double(opts.I);
            if size(D,3) == 1, G = D; else, G = 0.299*D(:,:,1)+0.587*D(:,:,2)+0.114*D(:,:,3); end
            % 半径范围：论文图的圆点标记直径通常 10~24 px。
            % ★ imfindcircles 要求半径 > 5，给它 rMin<6 会直接告警并返回空
            %   （实测踩过：默认自适应算出 rMin=3，圆检测全程 0 命中）。
            span = max(c1-c0, r1-r0);
            rMin = 6;
            rMax = max(8, min(22, round(span/22)));
            if isfield(opts,'minR'), rMin = max(6, opts.minR); end
            if isfield(opts,'maxR'), rMax = opts.maxR; end
            if rMax <= rMin, rMax = rMin + 6; end
            % ★ 关键：先用"圆盘腐蚀"把细曲线去掉，只留标记候选。
            %   为什么必须这么做：给 imfindcircles 的掩膜如果把曲线也算进去，
            %   "圆心挨着掩膜"这种校验就形同虚设 —— 实测曲线上的点会被大量
            %   检成"圆"（X≈3.08 处同时报出 Y=446 和 Y=202）。
            %   圆点标记是**实心圆盘**（直径 10~24 px），细线（3~5 px）开运算
            %   一下就没了，圆盘还在。腐蚀半径不能太大：取 0.6×最小半径，
            %   实测用 0.8 会把标记本身也消掉（圆检测变成 0 命中）。
            if exist('strel','file') && exist('imopen','file')
                r0e = max(2, round(rMin*0.6));
                diskM = imopen(ms, strel('disk', r0e));
            elseif exist('strel','file') && exist('imerode','file')
                r0e = max(2, round(rMin*0.6));
                diskM = imerode(ms, strel('disk', r0e));
            else
                diskM = ms;
            end
            % 圆度筛选（regionprops 的 Circularity = 4πA/P²，圆≈1）
            % ★ 必须初始化成 0×2 而不是 []：对 0×0 的空矩阵，
            %   candBlobs(end+1,:) 里的 end+1 是 **2** 而不是 1，
            %   赋值直接抛错（然后被外层 catch 吞掉，表现成"永远没有实心块"）。
            candBlobs = zeros(0,2);
            if exist('regionprops','file') && any(diskM(:))
                stb = regionprops(diskM, 'Area', 'Centroid', 'Circularity');
                for k = 1:numel(stb)
                    if stb(k).Area < 6, continue; end
                    circ = stb(k).Circularity;
                    if ~isfinite(circ) || circ < getf(opts,'minCirc',0.55), continue; end
                    % ★ regionprops 给的是**区域坐标**，必须加回裁剪偏移
                    %   才能与 imfindcircles 的整图坐标比较。
                    %   实测忘了加偏移时两边差 (c0-1, r0-1)，校验永远 0 通过。
                    candBlobs(end+1,:) = stb(k).Centroid + [c0-1, r0-1]; %#ok<AGROW>
                end
            end
            % 圆检测：在**整幅反相灰度**上跑（不要涂白 ROI，会破坏圆边缘）
            Gi = 255 - G;
            [cent, rad] = imfindcircles(Gi, [rMin rMax], ...
                'Sensitivity', opts.sens, 'Method', 'PhaseCode', ...
                'EdgeThreshold', 0.05);
            if ~isempty(cent)
                okc = cent(:,1) >= c0 & cent(:,1) <= c1 & cent(:,2) >= r0 & cent(:,2) <= r1;
                cent = cent(okc,:); rad = rad(okc);
                stat.nCand = size(cent,1);
                stat.nBlob = size(candBlobs,1);
                % 校验：圆心必须落在"开运算后仍在的实心块"附近。
                %   宽松一点（<= max(8, 1.5×rMin)）：圆心是拟合出来的，
                %   与块重心本来就会差几个像素。
                centAll = cent;                       % 过滤前留一份，便于诊断
                keep = false(size(cent,1),1);
                tolPx = max(8, 1.5*rMin);
                if getf(opts,'verbose',false)
                    fprintf(['    [detectMarkers] 掩膜 %d px；开运算后实心块 %d 个；' ...
                        '圆检测框内命中 %d 个\n'], nnz(ms), size(candBlobs,1), stat.nCand);
                    if ~isempty(candBlobs)
                        fprintf('      块重心：%s\n', mat2str(round(candBlobs(1:min(4,size(candBlobs,1)),:))));
                    end
                    if ~isempty(centAll)
                        fprintf('      圆心：  %s\n', mat2str(round(centAll(1:min(4,size(centAll,1)),:))));
                    end
                end
                for k = 1:size(cent,1)
                    if ~isempty(candBlobs)
                        dmin = min(sqrt(sum((candBlobs - cent(k,:)).^2, 2)));
                        if dmin <= tolPx, keep(k) = true; end
                        % 可选加严：要求圆周边界有足够覆盖率。
                        %   ★ 默认关闭：论文图里数据点普遍带**竖直误差棒**，
                        %   误差棒把圆环切开一段，真标记的覆盖率也只有 ~0.5，
                        %   开这个会把真标记误杀（实测 11 个点只认出 3 个）。
                        if keep(k) && getf(opts,'useRing',false)
                            frac = ringCoverage(ms, cent(k,:), rad(k), c0, r0);
                            if frac < getf(opts,'ringFrac',0.45), keep(k) = false; end
                        end
                    else
                        xc = round(cent(k,1)); yc = round(cent(k,2));
                        rr2 = max(2, round(rad(k)));
                        a0 = max(1, yc-r0+1-rr2); a1 = min(size(ms,1), yc-r0+1+rr2);
                        b0 = max(1, xc-c0+1-rr2); b1 = min(size(ms,2), xc-c0+1+rr2);
                        if a1 >= a0 && b1 >= b0 && ...
                           nnz(ms(a0:a1, b0:b1)) >= max(6, round(0.15*pi*rr2^2))
                            keep(k) = true;
                        end
                    end
                end
                cent = cent(keep,:);
                % 合并重复检测。阈值要按标记直径取：实测 6 px 太小，
                % 同一个标记会被报成 X=3.08 和 3.18 两个。
                cent = mergeClose(cent, max(10, 2.0*rMin));
                mk = [cent(:,1), cent(:,2)];
                stat.method = 'v2-imfindcircles';
                stat.nRound = size(mk,1);
                stat.nBar = 0; stat.nCols = 0;
                if getf(opts,'verbose',false)
                    fprintf('      校验保留 %d 个，合并后 %d 个\n', sum(keep), size(cent,1));
                end
                if ~isempty(mk)
                    [~, o] = sort(mk(:,1)); mk = mk(o,:);
                end
                return;
            end
            stat.method = 'v2-imfindcircles(无命中)';
        catch ME
            stat.method = sprintf('v2失败(%s)，回退v1', ME.message);
        end
    end

    % ---------------- v1：宽度判据（无 IPT 或圆检测无命中时的回退）----------------
    ncol = sum(ms, 1);
    if ~any(ncol), return; end
    on = ncol >= opts.minThick;
    d = diff([false, on, false]);
    ss = find(d==1); ee = find(d==-1)-1;
    stat.nCols = numel(ss);

    for k = 1:numel(ss)
        cols = ss(k):ee(k);
        wid = numel(cols);
        if wid < opts.minWidth
            stat.nBar = stat.nBar + 1;    % 太窄 -> 误差棒的竖段
            continue;
        end
        if wid > opts.maxWidth
            stat.nBar = stat.nBar + 1;    % 太宽 -> 图例色块/文字
            continue;
        end
        sub = ms(:, cols);
        rowCnt = sum(sub, 2);
        if ~any(rowCnt), continue; end
        [~, ri] = max(rowCnt);            % 圆心行 = 横向最宽的那一行
        lo = max(1, ri-2); hi = min(numel(rowCnt), ri+2);
        w = rowCnt(lo:hi)';
        rr = (lo:hi);
        yc = sum(w .* rr) / max(sum(w), eps);
        xc = mean(cols);
        mk(end+1,:) = [xc + c0 - 1, yc + r0 - 1]; %#ok<AGROW>
    end
    stat.nRound = size(mk,1);
    if isempty(mk)
        stat.method = [stat.method ' (v1: 无命中)'];
    end

    if ~isempty(mk)
        [~, o] = sort(mk(:,1));
        mk = mk(o,:);
    end
end

% ---------------------------------------------------------------------
function frac = ringCoverage(ms, cent, rad, c0, r0)
%RINGCOVERAGE  在半径 rad 的圆周上，有多少比例落在掩膜上
%   真圆形标记：边界是一整圈 -> 接近 1
%   曲线上的假圆：只有沿曲线那一侧有像素 -> 明显偏低
    frac = 0;
    if isempty(ms), return; end
    [H, W] = size(ms);
    rr = max(2, round(rad));
    th = linspace(0, 2*pi, max(12, round(2*pi*rr)));
    xs = round(cent(1) - c0 + 1 + rr*cos(th));
    ys = round(cent(2) - r0 + 1 + rr*sin(th));
    ok = xs >= 1 & xs <= W & ys >= 1 & ys <= H;
    if ~any(ok), return; end
    xs = xs(ok); ys = ys(ok);
    frac = nnz(ms(sub2ind([H W], ys, xs))) / numel(xs);
end

% ---------------------------------------------------------------------
function v = getf(s, f, d)
%GETF  读结构体字段，缺省则给默认值
    if isstruct(s) && isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end

% ---------------------------------------------------------------------
function c = mergeClose(c, minDist)
%MERGECLOSE  合并距离过近的圆心（同一圆被检到两次）
    if isempty(c), return; end
    keep = true(size(c,1),1);
    for a = 1:size(c,1)
        if ~keep(a), continue; end
        for b = a+1:size(c,1)
            if ~keep(b), continue; end
            if norm(c(a,:) - c(b,:)) < minDist, keep(b) = false; end
        end
    end
    c = c(keep,:);
end
