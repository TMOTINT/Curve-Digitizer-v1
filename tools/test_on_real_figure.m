function test_on_real_figure(whichCase)
%TEST_ON_REAL_FIGURE  用真实论文图做无交互回归测试（验证整条流水线）。
%
%   为什么用"与独立方法的一致率"而不是绝对精度：真实图没有真值。
%   独立方法 = 逐列找与种子颜色最接近的像素（不依赖追踪连通性）。
%   如果追踪跳到了别的曲线上，两者会系统性分离，一致率立刻掉下来。
%
%   用法：
%     test_on_real_figure            % 默认测 Fig.3 面板 C（两条异色曲线，可分）
%     test_on_real_figure('D')       % 测面板 D（11 条同色交叉曲线，演示难例）

    if nargin < 1 || isempty(whichCase), whichCase = 'C'; end
    imageFile = 'p05_img00_2190x1391.png';
    if ~exist(imageFile, 'file')
        error('找不到 %s，请把本脚本与图片放同一目录。', imageFile);
    end
    I = imread(imageFile);
    fprintf('图片 %s : %d x %d\n', imageFile, size(I,2), size(I,1));

    switch upper(whichCase)
        case 'C'    % 面板 C：蓝/红两条，几乎不重叠 —— 常规可解情况
            ax = struct('rowTop',41,'rowBottom',384,'colLeft',1620,'colRight',2152);
            cal.xFromPx = @(q) 0 + (q - 1620) * (50 - 0) / (2152 - 1620);
            cal.yFromPx = @(q) 0 + (q - 384) * (1.0 - 0) / (41 - 384);
            seed = [1800, 150];   % 落在蓝线的平台段（最可靠）
            tol  = 90;
        case 'D'    % 面板 D：11 条同色系绿/黑曲线，首尾汇聚且交叉 —— 难例
            ax = struct('rowTop',738,'rowBottom',1085,'colLeft',201,'colRight',733);
            cal.xFromPx = @(q) 0 + (q - 201) * (20 - 0) / (733 - 201);
            cal.yFromPx = @(q) -50 + (q - 1085) * (0 - (-50)) / (738 - 1085);
            seed = [350, 1000];
            tol  = 60;
        otherwise
            error('whichCase 只能是 C 或 D');
    end
    cal.xlim = [cal.xFromPx(ax.colLeft), cal.xFromPx(ax.colRight)];
    cal.ylim = [cal.yFromPx(ax.rowBottom), cal.yFromPx(ax.rowTop)];
    fprintf('面板 %s: 轴框 %dx%d px, X=[%.2f %.2f], Y=[%.2f %.2f]\n', ...
        upper(whichCase), ax.colRight-ax.colLeft, ax.rowBottom-ax.rowTop, ...
        cal.xlim, cal.ylim);

    % ---- 按种子颜色建掩膜（这才是工具的常规用法）----
    D = double(I);
    % 先把种子吸附到真正的曲线像素上（模拟工具里的 snapseed 步骤）
    [pt, seedCol, moved] = curveTools('snapseed', I, seed, 10);
    if moved
        fprintf('种子 (%d,%d) 吸附到曲线像素 (%d,%d)\n', seed(1), seed(2), pt(1), pt(2));
    else
        fprintf('种子 (%d,%d) 本身就在曲线像素上\n', pt(1), pt(2));
    end
    seed = pt;
    fprintf('种子颜色 RGB = [%d %d %d]\n', round(seedCol));
    dr = D(:,:,1)-seedCol(1); dg = D(:,:,2)-seedCol(2); db = D(:,:,3)-seedCol(3);
    m = (dr.^2 + dg.^2 + db.^2) <= tol^2;
    box = false(size(m));
    box(round(ax.rowTop)+1:round(ax.rowBottom)-1, ...
        round(ax.colLeft)+1:round(ax.colRight)-1) = true;
    m = m & box;
    fprintf('颜色掩膜: %d 个像素 (%.2f%% 的轴框面积)\n', nnz(m), 100*nnz(m)/nnz(box));

    cfg = struct('mask', m, 'radius', 6, 'colorTol', tol);
    [res, info] = curveTools('trace', I, ax, cal, seed, cfg);
    calM = cal; calM.mask = res.mask;
    [X, Y, bi] = curveTools('reduce', res.pathPx, calM, 'fit');

    fprintf('\n追踪: %d 点 / %d 列, X=[%.2f %.2f], Y=[%.2f %.2f]\n', ...
        info.nPts, numel(unique(res.pathPx(:,1))), min(X), max(X), min(Y), max(Y));
    fprintf('归约: %d 点, 多值列 %d (%.1f%%)\n', ...
        numel(X), bi.overlap, 100*bi.overlap/numel(X));

    % ---- 独立方法：逐列找与种子颜色最接近的像素 ----
    distCol = (D(:,:,1)-seedCol(1)).^2 + (D(:,:,2)-seedCol(2)).^2 + ...
              (D(:,:,3)-seedCol(3)).^2;
    cc = round(ax.colLeft)+2:round(ax.colRight)-2;
    rr0 = round(ax.rowTop)+2; rr1 = round(ax.rowBottom)-2;
    rawRow = nan(numel(cc),1); rawD = nan(numel(cc),1);
    for k = 1:numel(cc)
        seg = distCol(rr0:rr1, cc(k));
        [mn, r] = min(seg);
        rawRow(k) = rr0 + r - 1;
        rawD(k)   = sqrt(mn);
    end
    med = movmedian(rawRow, 41, 'omitnan');
    keep = abs(rawRow - med) < 12 & rawD < tol & abs(rawRow - seed(2)) < 120;
    Xc = cal.xFromPx(cc(keep)');
    Yc = cal.yFromPx(rawRow(keep));
    Xc = Xc(:); Yc = Yc(:);
    fprintf('独立方法: %d 点, X=[%.2f %.2f], Y=[%.2f %.2f]\n', ...
        numel(Xc), min(Xc), max(Xc), min(Yc), max(Yc));

    % ---- 一致率 ----
    inR = Xc >= min(X) & Xc <= max(X);
    if nnz(inR) < 10
        fprintf('!! 两者公共区间太小（只有 %d 个可比点），无法比较\n', nnz(inR));
        agree = 0;
    else
        Yon = interp1(X, Y, Xc(inR), 'linear');
        dAll = Yon - Yc(inR);
        tolV = 0.02 * (max(cal.ylim) - min(cal.ylim));   % 容差 = Y 量程的 2%
        agree = mean(abs(dAll) <= tolV);
        fprintf('一致率: %.1f%%  (|ΔY| <= %.3f, 即 Y 量程的 2%%)\n', 100*agree, tolV);
        fprintf('  差异分位: 中位 %.4f, 90%% %.4f, 最大 %.4f\n', ...
            median(abs(dAll)), prctile(abs(dAll),90), max(abs(dAll)));
    end

    % ---- 质量指标：与独立方法的一致率 + 曲线平滑度 ----
    % 不用"相邻点跳变次数"：平直段相邻差本来就接近 0，比值会虚高、没有意义。
    d2 = abs(diff(Y, 2));
    fracRough = mean(d2 > 0.05*(max(cal.ylim) - min(cal.ylim)));
    fprintf('平滑度: 二阶差分超过量程 5%% 的比例 = %.1f%%\n', 100*fracRough);

    curves = struct('name', sprintf('real_panel%s', upper(whichCase)), ...
                    'X', X, 'Y', Y, 'pathPx', res.pathPx);
    curveTools('overlay', I, ax, cal, curves);

    ok = agree >= 0.8 && fracRough <= 0.05 && numel(X) > 100;
    fprintf('\n判定: %s\n', tern(ok, '通过', '需要人工检查'));
    if ~ok && upper(whichCase) == 'D'
        fprintf('面板 D 有 11 条同色系曲线且首尾汇聚，自动追踪容易跳线 —— 这正是工具的已知边界。\n');
    end
end

function s = tern(c, a, b)
    if c, s = a; else, s = b; end
end
