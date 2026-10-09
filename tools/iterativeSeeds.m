function cand = iterativeSeeds(I, ax, opts)
%ITERATIVESEEDS  "提一条 -> 挖掉一条 -> 再提下一条"的候选发现器
%
%   cand = iterativeSeeds(I, ax, opts)
%
%   ==================== 为什么这条路最可靠 ====================
%   前面几种方法都在试图"一次性把图里的颜色分成几类"，但抗锯齿会把一条线
%   的颜色糊成连续分布，于是：
%     · 颜色直方图 -> 同色系多条并成一条、颜色被平均；
%     · 颜色分层   -> 一条线被抗锯齿切成好几层；
%     · 跨列归组   -> 相邻列接错、两三条串成一条。
%   本函数换思路：不分类，而是逐条"提走"。
%     ① 在当前掩膜里找一条最有代表性的曲线（像素最多的那一段实芯色）；
%     ② 用 traceByDP 把它整条取出来；
%     ③ 把这条路径附近的像素从掩膜里挖掉（几何挖除，不是按颜色挖）；
%     ④ 回到 ①，直到掩膜里没有像样的东西。
%
%   关键点是第 ③ 步用几何挖除：只挖掉离这条路径 2~3 px 以内的像素，
%   这样同色系相邻的曲线（通常相距 8 px 以上）不会被误挖掉。
%
%   opts:
%     .maxCurves  最多提几条（默认 16）
%     .minPix     残余掩膜少于这么多像素就停（默认 120）
%     .wipe       沿路径挖除的半宽（默认 3 px）
%     .minSpanFrac 一条曲线至少横跨轴框宽的比例（默认 0.25）

    if nargin < 3, opts = struct(); end
    maxCurves   = getf(opts,'maxCurves',16);
    minPix      = getf(opts,'minPix',120);
    wipe        = getf(opts,'wipe',3);
    minSpanFrac = getf(opts,'minSpanFrac',0.25);

    cand = struct('color', {}, 'size', {}, 'seed', {}, 'yMean', {}, ...
                  'spanX', {}, 'from', {});

    D = double(I);
    [H, W, ~] = size(D);
    if size(D,3) < 3, return; end
    r0 = max(1, round(ax.rowTop)+2);  r1 = min(H, round(ax.rowBottom)-2);
    c0 = max(1, round(ax.colLeft)+2); c1 = min(W, round(ax.colRight)-2);
    if r1 <= r0 || c1 <= c0, return; end
    % 行走区必须与掩膜裁剪区一致，否则 traceByDP 会走到掩膜之外
    %   （实测：行走区给整幅、掩膜只留轴框内，种子与路径就会错位）
    wr0 = r0; wr1 = r1; wc0 = c0; wc1 = c1;

    % ---- 工作掩膜：轴框内的"彩色像素" ----
    mx = max(D,[],3); mn = min(D,[],3);
    lum = 0.299*D(:,:,1) + 0.587*D(:,:,2) + 0.114*D(:,:,3);
    mask = ((mx - mn) >= 45) & (lum <= 242);
    keepR = false(H,1); keepR(r0:r1) = true;
    keepC = false(1,W); keepC(c0:c1) = true;
    mask = mask & (keepR * keepC);

    minSpanPx = minSpanFrac * (c1 - c0);

    for it = 1:maxCurves
        if nnz(mask) < minPix, break; end

        % ---- ① 找当前掩膜里"最实芯"的色团 ----
        [sd, refCol] = pickSeedFromMask(D, mask, r0, r1, c0, c1);
        if isempty(sd), break; end

        % ---- ② DP 提取这条 ----
        [xs, ys] = traceByDP(D, wr0, wr1, wc0, wc1, sd, refCol, opts);
        if getf(opts,'dbg',false)
            fprintf('  [iter] 第 %d 条：种子[%d %d] 色[%d %d %d]', it, round(sd), round(refCol));
            if isempty(xs)
                fprintf('  路径空\n');
            else
                fprintf('  路径 y %.0f..%.0f（%d 点）\n', min(ys), max(ys), numel(ys));
            end
        end
        if numel(xs) < 40, break; end
        span = max(xs) - min(xs);
        if span < minSpanPx, break; end

        cand(end+1) = struct('color', refCol, 'size', nnz(mask), ...
            'seed', sd, 'yMean', mean(ys), 'spanX', span, ...
            'from', 'iter'); %#ok<AGROW>

        % ---- ③ 几何挖除：把路径附近 wipe 像素内的掩膜清掉 ----
        nBefore = nnz(mask);
        if getf(opts,'dbg',false)
            fprintf('  [iter]   挖除参数 wr0=%d wr1=%d wipe=%d  路径列 %d..%d\n', ...
                wr0, wr1, wipe, round(min(xs)), round(max(xs)));
        end
        for k = 1:numel(xs)
            cc = round(xs(k));
            if cc < wc0 || cc > wc1, continue; end
            ra = max(wr0, floor(ys(k) - wipe));
            rb = min(wr1, ceil(ys(k) + wipe));
            if ra < 1 || rb > size(mask,1), continue; end
            mask(ra:rb, cc) = false;
        end
        if getf(opts,'dbg',false)
            fprintf('  [iter] 第 %d 条：掩膜 %d -> %d 像素  种子[%d %d] 色[%d %d %d]  路径 y %.0f..%.0f (%d 点)\n', ...
                it, nBefore, nnz(mask), round(sd), round(refCol), min(ys), max(ys), numel(ys));
        end
    end

    % 按纵向位置排序（与图例顺序通常一致）
    if ~isempty(cand)
        [~, o] = sort([cand.yMean]);
        cand = cand(o);
    end
end

%
function [sd, refCol] = pickSeedFromMask(D, mask, r0, r1, c0, c1)
%PICKSEEDFROMMASK  在当前残余掩膜里取一个新的种子
%
%   取法：找掩膜里最靠左的那一列，在它里面挑"最厚的一段"的中心。
%   为什么这么简单反而最可靠：
%     前面每提走一条曲线，都会把它经过的列全部挖掉（几何挖除）。
%     所以"残余掩膜里最靠左的列"必然不在任何已提路径的覆盖范围内 ——
%     种子一定属于一条还没提过的曲线。
%     避免反复在相同列播种。
    sd = []; refCol = [];
    colCount = sum(mask(r0:r1, c0:c1), 1);
    nz = find(colCount > 0);
    if isempty(nz), return; end
    c = c0 + nz(1) - 1;                     % 最靠左的残余列

    rowsC = find(mask(r0:r1, c)) + r0 - 1;
    if isempty(rowsC), return; end
    d = diff(rowsC);
    brk = find(d > 1);
    segs = {}; s = 1;
    for k = 1:numel(brk), segs{end+1} = rowsC(s:brk(k)); s = brk(k)+1; end %#ok<AGROW>
    segs{end+1} = rowsC(s:end);
    [~, bi] = max(cellfun(@numel, segs));
    seg = segs{bi};
    if isempty(seg), return; end

    % 参考色取该段中间像素的颜色（段中心最可能是实芯）
    rm = seg(round(numel(seg)/2));
    refCol = reshape(D(rm, c, :), 1, 3);
    sd = [c, rm];
end

%
function v = getf(s, f, d)
    if isstruct(s) && isfield(s, f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end
