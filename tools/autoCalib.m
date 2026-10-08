function S = autoCalib(I, varargin)
%AUTOCALIB  从一张完整图里自动找出轴框与刻度，算出像素↔数值映射
%
%   S = autoCalib(I)
%   S = autoCalib(I, 'xStep', 0.2, 'yStep', 50)     % 已知"一格"的值
%
%   ==================== 思路（利用图上清晰的刻度）====================
%   ① 找轴框：整图里找最长的横线段与竖线段，成对的长线就是四条轴脊。
%      这两张图的轴框都是完整矩形，所以取"最长的 2 条横线 + 最长的 2 条竖线"。
%   ② 找刻度：轴脊内侧的短横/短竖段（刻度是朝内画的），长度 5~40 px；
%      合并相邻 2 px 内的重复（抗锯齿会把一条刻线测成 2~3 行）。
%   ③ 定标注值：刻度通常是等差数列，间距 d_px 对应标注步长 v。
%      用户只需给出一个标注步长（例如 x 每 0.2 一格、y 每 50 一格），
%      程序把刻度序号拟合成 value = v*(k - k0) + value0，再用轴框四边反推范围。
%      若不给步长，就只返回像素几何，由调用方决定。
%
%   返回 S 结构：frame=[上 下 左 右]（整图像素坐标）
%                tickX/tickY 刻线的像素坐标（列/行）
%                cal 标定句柄与范围

    p = inputParser;
    addParameter(p,'xStep',[],@(x)isempty(x)||isscalar(x));
    addParameter(p,'yStep',[],@(x)isempty(x)||isscalar(x));
    addParameter(p,'quiet',false,@islogical);
    parse(p,varargin{:});
    O = p.Results;

    D = double(I);
    [H, W, ~] = size(D);
    gray = 0.299*D(:,:,1) + 0.587*D(:,:,2) + 0.114*D(:,:,3);
    dark = gray < 128;

    % ---------- ① 找最长横线 / 竖线 ----------
    [fr, ~] = longestLines(dark, H, W);
    S = struct('frame', fr, 'tickX', [], 'tickY', [], 'cal', [], 'ok', false);
    if any(isnan(fr)), return; end
    rT = fr(1); rB = fr(2); cL = fr(3); cR = fr(4);
    if rB - rT < 30 || cR - cL < 30, return; end

    % ---------- ② 找刻度 ----------
    S.tickY = ticksOnSpine(dark, rT, rB, cL, cR, 'left');
    S.tickX = ticksOnSpine(dark, rT, rB, cL, cR, 'bottom');

    % ---------- ③ 定标注值 ----------
    cal = struct();
    if ~isempty(O.xStep) && numel(S.tickX) >= 3
        v = fitTicks(S.tickX, O.xStep, cL, cR);
    else
        v = [];
    end
    if ~isempty(O.yStep) && numel(S.tickY) >= 3
        vy = fitTicks(S.tickY, O.yStep, rB, rT);   % 注意 y 向下增大，值向上增大
    else
        vy = [];
    end
    if isempty(v) || isempty(vy), return; end

    % v = [lo hi]（轴框两边对应的值），vy = [lo hi]
    cal.xFromPx = @(px) v(1) + (px - cL) * (v(2)-v(1)) / (cR - cL);
    cal.yFromPx = @(px) vy(1) + (rB - px) * (vy(2)-vy(1)) / (rB - rT);
    cal.xlim = v; cal.ylim = vy;
    cal.method = 'auto-ticks'; cal.confidence = 0.9;
    S.cal = cal; S.ok = true;

    if ~O.quiet
        fprintf('  轴框 rows %d..%d cols %d..%d\n', rT, rB, cL, cR);
        fprintf('  x 刻线 %d 条，间距中位 %.2f px -> 每格 %.4g\n', ...
            numel(S.tickX), medDiff(S.tickX), O.xStep);
        fprintf('  y 刻线 %d 条，间距中位 %.2f px -> 每格 %.4g\n', ...
            numel(S.tickY), medDiff(S.tickY), O.yStep);
        fprintf('  标定后范围：X [%.4g, %.4g]  Y [%.4g, %.4g]\n', v(1), v(2), vy(1), vy(2));
    end
end

%
function [fr, info] = longestLines(dark, H, W)
%LONGESTLINES  取最长的 2 条横线与最长的 2 条竖线作为轴框
    fr = [NaN NaN NaN NaN]; info = struct();
    % 横线：每行的最长连续暗游程
    rowLen = zeros(H,1); rowSeg = zeros(H,2);
    for r = 1:H
        d = diff([false, dark(r,:), false]);
        s = find(d==1); e = find(d==-1)-1;
        if isempty(s), continue; end
        [mx, ix] = max(e - s + 1);
        rowLen(r) = mx; rowSeg(r,:) = [s(ix) e(ix)];
    end
    thrR = 0.5 * max(rowLen);
    candR = find(rowLen >= max(thrR, 0.4*W));
    [fr(1), fr(2)] = pickTwo(candR, rowSeg, rowLen);
    % 竖线
    colLen = zeros(1,W); colSeg = zeros(W,2);
    for c = 1:W
        d = diff([false; dark(:,c); false]);
        s = find(d==1); e = find(d==-1)-1;
        if isempty(s), continue; end
        [mx, ix] = max(e - s + 1);
        colLen(c) = mx; colSeg(c,:) = [s(ix) e(ix)];
    end
    thrC = 0.5 * max(colLen);
    candC = find(colLen >= max(thrC, 0.4*H));
    [fr(3), fr(4)] = pickTwo(candC, colSeg, colLen);
end

%
function [a, b] = pickTwo(cand, seg, len)
%PICKTWO  从候选里取轴框的两条对边
%
%   踩过的坑：粗线（2~3 px）会被测成相邻的 2~3 行，直接取"最上/最下"
%     会得到同一条线的上下沿（实测返回 rows 263..264，跨度 2 px）。
%   做法：先把相距 <= 3 px 的候选合并成一条（取中心），再取最外两条。
    a = NaN; b = NaN;
    if isempty(cand), return; end
    cand = sort(cand(:)');
    merged = cand(1);
    for k = 2:numel(cand)
        if cand(k) - merged(end) <= 3
            merged(end) = round((merged(end) + cand(k))/2);
        else
            merged(end+1) = cand(k); %#ok<AGROW>
        end
    end
    if numel(merged) < 2
        a = merged(1); b = merged(end);
        return;
    end
    % 在"长度最大的前若干条"里取最外的两条（避免被细碎的网格线干扰）
    [~, o] = sort(len(cand), 'descend');
    strong = cand(o(1:min(numel(cand), 8)));
    strong = unique(round(strong));
    a = min(strong); b = max(strong);
    if b - a < 30
        a = merged(1); b = merged(end);
    end
    if false, seg = seg; end %#ok<NASGU>
end

%
function t = ticksOnSpine(dark, rT, rB, cL, cR, side)
%TICKSONSPINE  在轴脊内侧找刻线（短线段），返回绝对坐标并去重
    t = [];
    switch side
        case 'left'
            band = dark(rT:rB, min(cL+3,size(dark,2)) : min(cL+45,size(dark,2)));
            for r = 1:size(band,1)
                d = diff([false, band(r,:), false]);
                s = find(d==1); e = find(d==-1)-1;
                for k = 1:numel(s)
                    L = e(k)-s(k)+1;
                    if L >= 5 && L <= 45 && s(k) <= 4
                        t(end+1) = rT + r - 1; %#ok<AGROW>
                        break;
                    end
                end
            end
        case 'right'
            band = dark(rT:rB, max(cL,size(dark,2)-45) : max(cL,size(dark,2)-3));
            for r = 1:size(band,1)
                d = diff([false, band(r,:), false]);
                s = find(d==1); e = find(d==-1)-1;
                for k = 1:numel(s)
                    L = e(k)-s(k)+1;
                    if L >= 5 && L <= 45 && e(k) >= size(band,2)-3
                        t(end+1) = rT + r - 1; %#ok<AGROW>
                        break;
                    end
                end
            end
        case 'bottom'
            band = dark(max(rT,size(dark,1)-45) : max(rT,size(dark,1)-3), cL:cR);
            for c = 1:size(band,2)
                v = band(:,c);
                d = diff([false; v; false]);
                s = find(d==1); e = find(d==-1)-1;
                for k = 1:numel(s)
                    L = e(k)-s(k)+1;
                    if L >= 5 && L <= 45 && e(k) >= size(band,1)-3
                        t(end+1) = cL + c - 1; %#ok<AGROW>
                        break;
                    end
                end
            end
    end
    if isempty(t), return; end
    t = sort(t(:)');
    % 去重：相距 <= 2 px 的合成一条（抗锯齿会把一条刻线测成 2~3 行）
    keep = true(1, numel(t)); acc = t(1); n = 1;
    out = t(1);
    for k = 2:numel(t)
        if t(k) - out(end) <= 2
            acc(end) = acc(end) + t(k); n(end) = n(end) + 1;
            out(end) = round(acc(end)/n(end));
        else
            out(end+1) = t(k); acc(end+1) = t(k); n(end+1) = 1; %#ok<AGROW>
        end
    end
    if false, keep = keep; end %#ok<NASGU>
    t = out;
end

%
function v = fitTicks(t, step, edgeLo, edgeHi)
%FITTICKS  把刻线位置拟合成等差数列，外推到轴框两边，返回 [边Lo的值, 边Hi的值]
%   做法：算相邻间距的中位数 d_px，则 value 每 d_px 走一个 step。
%   再用"每个刻线相对第一条的序号"做最小二乘，得到 value(x) = a*x + b，
%   最后代到 edgeLo / edgeHi。
    if numel(t) < 2, v = []; return; end
    t = sort(t(:));
    d = diff(t);
    d = d(d >= 3);                       % 丢掉因漏检产生的过小间距
    if isempty(d), v = []; return; end
    dpx = median(d);
    if dpx <= 0, v = []; return; end
    % 序号：以第一条为 0
    k = round((t - t(1)) / dpx);
    if numel(unique(k)) < 3, v = []; return; end
    % value = step * k + b  -> 拟合 b（step 已知，所以只解 b）
    val = step * k(:);
    b = mean(val - step*k(:)) + 0;       %#ok<NASGU>  占位（下两行才是真拟合）
    % 用最小二乘解 value = A*x + B
    A = [t(:), ones(numel(t),1)] \ (step*k(:));
    vAt = @(x) A(1)*x + A(2);
    v = [vAt(edgeLo), vAt(edgeHi)];
end

%
function d = medDiff(t)
    if numel(t) < 2, d = NaN; return; end
    x = diff(sort(t(:)));
    x = x(x >= 3);
    if isempty(x), d = NaN; else, d = median(x); end
end
