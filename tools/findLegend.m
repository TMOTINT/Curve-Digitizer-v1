function leg = findLegend(I, ax, opts)
%FINDLEGEND  定位图例（**以样本线段为锚点**），并给出要排除的区域与各样本色
%
%   ==================== 为什么重写 ====================
%   图例里的"样本线"（例如 `—●—`）跟真曲线长得几乎一样：同颜色、同线宽、
%   也够长。它们一旦被当成曲线，就会出现"实际 2 条却识别出 5 条"
%   （实测 Fig.3C）、"把图标当曲线"（实测 Fig.3E）这类问题。
%
%   ==================== 判据（不依赖边框，因为多数图例没有边框）====================
%   图例样本的本质特征，按可靠性排序：
%     ① **成组**：同一图例里各样本线的长度几乎一样（同一段绘制代码）
%     ② **左端对齐**：样本线是一列排下来的，左端 x 基本一致
%     ③ **纵向等距**：相邻样本的纵向间距相近
%   这三条一起用，就能把"两条真曲线在图中偶然平行"排除掉 ——
%   真曲线不会左端严格对齐、也不会等距排成一列。
%
%   用法: leg = findLegend(I, ax)
%   返回:
%     leg.found / .rect / .boxes / .colors / .yCenters / .n
%   其中 .rect = [x0 y0 x1 y1] 是要从曲线检测里**排除**的区域
%   （向右延伸到文字结束，避免文字笔画被当成小图块）。

    if nargin < 3, opts = struct(); end
    if ~isfield(opts,'minLen'),   opts.minLen = 18;  end   % 样本线最短
    if ~isfield(opts,'maxLen'),   opts.maxLen = 140; end   % 样本线最长
    if ~isfield(opts,'maxThick'), opts.maxThick = 22; end  % 带标记的样本会厚一些
    if ~isfield(opts,'minGroup'), opts.minGroup = 2; end
    if ~isfield(opts,'verbose'),  opts.verbose = false; end

    leg = struct('found',false,'rect',[],'boxes',zeros(0,4), ...
                 'colors',zeros(0,3),'yCenters',zeros(0,1),'n',0);
    if size(I,3) == 1, I = repmat(I,1,1,3); end
    D = double(I);
    [H, W, ~] = size(D);
    mx = max(D,[],3); mn = min(D,[],3);
    sat = mx - mn;
    lum = 0.299*D(:,:,1) + 0.587*D(:,:,2) + 0.114*D(:,:,3);
    % 样本线是"有颜色且不太亮"或"深灰黑"的笔画
    inkAll = ((sat >= 45) & (lum <= 242)) | (lum <= 150);

    % ---- 在轴框内找所有"横细段"连通块 ----
    c0 = max(1, round(ax.colLeft)+1); c1 = min(W, round(ax.colRight)-1);
    r0 = max(1, round(ax.rowTop)+1);  r1 = min(H, round(ax.rowBottom)-1);
    if c1 <= c0 || r1 <= r0, return; end
    m = false(H, W);
    m(r0:r1, c0:c1) = inkAll(r0:r1, c0:c1);

    boxes = zeros(0,4); cols = zeros(0,3);
    if exist('regionprops','file')
        st = regionprops(m, 'BoundingBox', 'Area', 'PixelIdxList');
        for k = 1:numel(st)
            bb = st(k).BoundingBox;                  % [x y w h]
            if bb(3) < opts.minLen || bb(3) > opts.maxLen, continue; end
            if bb(4) > opts.maxThick, continue; end
            if bb(3) < 2.0*bb(4), continue; end       % 必须扁长
            boxes(end+1,:) = [bb(1), bb(2), bb(1)+bb(3)-1, bb(2)+bb(4)-1];
            % 该块的主色：在块的子图里取最饱和的 40% 像素求均值（抗锯齿拉不灰）
            %   ★ 注意 regionprops 的 PixelIdxList 是**单通道线性下标**，
            %     不能拿它加偏移去索引三通道（实测越界：索引超过元素总数）。
            rr = max(1,floor(bb(2))) : min(H, ceil(bb(2)+bb(4)-1));
            cc = max(1,floor(bb(1))) : min(W, ceil(bb(1)+bb(3)-1));
            sub = D(rr, cc, :);
            sub = reshape(sub, [], 3);
            s2 = max(sub,[],2) - min(sub,[],2);
            [~, o] = sort(s2, 'descend');
            take = o(1:max(1, round(0.4*numel(o))));
            cols(end+1,:) = mean(sub(take,:), 1);
        end
    end
    if size(boxes,1) < opts.minGroup, return; end

    % ---- 按"长度相近 + 左端对齐"分组，再看纵向是否等距 ----
    len = boxes(:,3) - boxes(:,1) + 1;
    best = [];
    for a = 1:size(boxes,1)
        grp = find(abs(len - len(a)) <= max(6, 0.25*len(a)) & ...
                   abs(boxes(:,1) - boxes(a,1)) <= 14);
        if numel(grp) < opts.minGroup, continue; end
        yc = (boxes(grp,2) + boxes(grp,4)) / 2;
        ys = sort(yc);
        gaps = diff(ys);
        if isempty(gaps), continue; end
        uneven = std(gaps) / max(median(gaps), eps);
        if uneven > 0.6, continue; end                 % 不等距 -> 不是图例
        % 评分：组内数量优先，其次"间距更均匀、长度更一致"
        score = numel(grp) - uneven - std(len(grp))/max(1,mean(len(grp)));
        if isempty(best) || score > best.score
            best = struct('grp',grp,'score',score,'uneven',uneven);
        end
    end
    if isempty(best), return; end

    g = best.grp;
    boxes = boxes(g,:); cols = cols(g,:);
    [~, o] = sort(boxes(:,2));
    boxes = boxes(o,:); cols = cols(o,:);

    % ---- 排除区域：样本线外接框，向右延伸到文字结束 ----
    %   ★ 两个坑都在这一小段里，务必保留写法：
    %     1) 循环变量别用 c / cc / j / i：MATLAB 把它们当复数
    %        （c = 0+1i、cc = 0+1.0000i），当下标报"索引无效"；
    %     2) 行/列下标必须显式取整：ax 里给的边界可能是 x.5 这类小数，
    %        而 MATLAB 不允许用非整数作下标（报"位置 2 的索引无效"）。
    x0 = min(boxes(:,1)); x1 = max(boxes(:,3));
    y0 = min(boxes(:,2)); y1 = max(boxes(:,4));
    x1 = min(W, max(1, round(x1)));
    rr = max(1, round(r0)) : min(H, round(r1));
    lim = min(W, x1 + round(0.45*(c1-c0)));
    if lim > x1
        colList = (x1+1):lim;
        for kk = 1:numel(colList)
            kcol = max(1, min(W, round(colList(kk))));
            seg = 0.299*D(rr,kcol,1) + 0.587*D(rr,kcol,2) + 0.114*D(rr,kcol,3);
            if any(seg < 120), x1 = kcol; end
        end
    end
    pad = 6;
    leg.rect = [max(1,x0-pad), max(1,y0-pad), min(W,x1+pad), min(H,y1+pad)];
    leg.boxes = boxes; leg.colors = cols;
    leg.yCenters = (boxes(:,2) + boxes(:,4))/2;
    leg.n = size(boxes,1);
    leg.found = true;

    if opts.verbose
        fprintf(['  [findLegend] 找到图例：%d 个样本，排除区域 x%d-%d y%d-%d；' ...
                 '样本色 '], leg.n, round(leg.rect));
        for k = 1:leg.n, fprintf('[%3.0f %3.0f %3.0f] ', cols(k,:)); end
        fprintf('\n');
    end
end
