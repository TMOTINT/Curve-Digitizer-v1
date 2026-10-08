function selftest_curvetools()
%SELFTEST_CURVETOOLS  闭环自检：全自动、无交互，验证标定+追踪+归约的正确性。
%
%   构造合成图：白色背景 + 一条已知解析式的黑线，走完整流程后与解析解比较。
%   换算法后请先跑这个，再拿去处理真图。
%
%   用法：cd 到本文件所在目录，运行 selftest_curvetools

    fprintf('=== curveTools 自检 ===\n');
    pass = true;

    % ================= 1. 合成图 + 全流程 =================
    H = 700; W = 1400;
    px = (300:1200)';
    pyTrue = 200 + 300*exp(-(px-300)/220);        % 单调衰减到平台

    I = 255*ones(H, W, 3, 'uint8');
    for k = -1:1                                  % 1~3 px 线宽
        r = round(pyTrue) + k;
        ok = r >= 1 & r <= H;
        for ch = 1:3
            chI = I(:,:,ch);
            chI(sub2ind([H W], r(ok), px(ok))) = 0;
            I(:,:,ch) = chI;
        end
    end
    rng(0);
    n = 4000;                                     % 椒盐噪声
    rr = randi(H, n, 1); cc = randi(W, n, 1);
    for ch = 1:3
        chI = I(:,:,ch);
        chI(sub2ind([H W], rr, cc)) = uint8(randi([0 255], n, 1));
        I(:,:,ch) = chI;
    end
    fprintf('合成图像 %dx%d，曲线 y = 200 + 300*exp(-(x-300)/220)\n', W, H);

    ax = struct('rowTop',50,'rowBottom',650,'colLeft',200,'colRight',1300);
    cal.xFromPx = @(q) 0 + (q - 200) * 10 / (1300 - 200);
    cal.yFromPx = @(q) 0 + (q - 650) * 600 / (50 - 650);
    cal.xlim = [0 10]; cal.ylim = [0 600];

    [res, info] = curveTools('trace', I, ax, cal, ...
                             [px(1), round(pyTrue(1))], ...
                             struct('colorTol',60,'radius',6));
    [X, Y, ~] = curveTools('reduce', res.pathPx, calWithMask(cal, res.mask), 'fit');

    % 还原到像素坐标与解析解比较
    pyBack = 650 + Y * (50 - 650) / 600;
    pxBack = 200 + X * (1300 - 200) / 10;
    ok = pxBack >= px(1) & pxBack <= px(end);
    pyRef = 200 + 300*exp(-(pxBack(ok)-300)/220);
    err = pyBack(ok) - pyRef;

    fprintf('\n--- 全流程结果 ---\n');
    fprintf('追踪点数        : %d (覆盖 %d 像素列)\n', info.nPts, numel(unique(res.pathPx(:,1))));
    fprintf('归约后数据点    : %d\n', numel(X));
    fprintf('X 范围          : [%.4f, %.4f]  (期望 [%.4f, %.4f])\n', ...
        min(X), max(X), cal.xFromPx(px(1)), cal.xFromPx(px(end)));
    fprintf('像素还原误差    : 均值 %.3f px, 最大 %.3f px, RMS %.3f px\n', ...
        mean(abs(err)), max(abs(err)), sqrt(mean(err.^2)));

    % 误差集中在哪一段？按列位置分三段统计
    idxAll = find(ok);
    seg = round(linspace(1, numel(err), 4));
    for s = 1:3
        a = seg(s); b = seg(s+1);
        fprintf('  列 %4d~%4d: 均值 %.2f, 最大 %.2f px (该段 |dy/dx| 约 %.2f)\n', ...
            round(pxBack(idxAll(a))), round(pxBack(idxAll(min(b,end)))), ...
            mean(abs(err(a:b))), max(abs(err(a:b))), ...
            abs(mean(diff(pyRef(a:b))./diff(pxBack(idxAll(a:b))))));
    end
    [~, imax] = max(abs(err));
    fprintf('  最大误差出现在 x=%d (原始曲线 y=%.1f, |dy/dx|=%.2f)\n', ...
        round(pxBack(idxAll(imax))), pyRef(imax), ...
        abs(300/220*exp(-(pxBack(idxAll(imax))-300)/220)));

    if abs(min(X) - cal.xFromPx(px(1))) > 0.03
        fprintf('!! X 起点偏差过大\n'); pass = false; end
    if abs(max(X) - cal.xFromPx(px(end))) > 0.03
        fprintf('!! X 终点偏差过大\n'); pass = false; end
    if numel(X) < 800
        fprintf('!! 数据点太少（应接近 901 列）\n'); pass = false; end
    % 注意：合成"真值"本身用了 round()，一列在陡峭段跨多行，量化下限约 0.5~1.5 px。
    % 所以阈值取 2.5 px 而不是 1 px —— 这里卡的是算法有没有系统偏差，不是绝对精度。
    if max(abs(err)) > 2.5
        fprintf('!! 像素误差超过 2.5 px\n'); pass = false; end

    % ================= 2. 归约：抗离群 =================
    % 第 4 列多了一个被标记符号污染的远点；最小二乘应给出中心线而不是被拉走
    p = [1 100; 1 102; 1 104; 2 100; 2 102; 2 104; 3 100; 3 102; 3 104; ...
         4 100; 4 150; 4 104];
    calI.xFromPx = @(q) q; calI.yFromPx = @(q) q;
    [Xr, Yr, ~] = curveTools('reduce', p, calI, 'fit');
    y4 = Yr(abs(Xr - 4) < 1e-9);
    ok4 = abs(y4 - 101.7) < 6;
    fprintf('\n归约抗离群   : 第4列 = %.2f (期望约 101.7, 容忍 6) -> %s\n', ...
        y4, tern(ok4,'OK','FAIL'));
    if ~ok4, pass = false; end

    % ================= 3. 归约：陡峭段无系统偏差 =================
    Xs = []; Ys = [];
    for c = 10:20
        Xs = [Xs; c*ones(4,1)]; %#ok<AGROW>
        Ys = [Ys; 2*c + (-1.5:1.5)']; %#ok<AGROW>
    end
    [Xr2, Yr2, ~] = curveTools('reduce', [Xs Ys], calI, 'fit');
    dev = Yr2 - 2*Xr2;
    ok5 = max(abs(dev)) < 0.05;
    fprintf('归约陡峭段   : 斜率2直线上最大偏差 %.4f px -> %s\n', ...
        max(abs(dev)), tern(ok5,'OK','FAIL'));
    if ~ok5, pass = false; end

    % ================= 4. 归约：多值检测 =================
    p2 = [1 10; 1 11; 2 20; 2 21; 3 10; 3 60; 4 10; 4 11];
    [~, ~, bi2] = curveTools('reduce', p2, calI, 'fit');
    ok6 = bi2.overlap >= 1;
    fprintf('多值列检测   : overlap=%d (应 >=1) -> %s\n', bi2.overlap, tern(ok6,'OK','FAIL'));
    if ~ok6, pass = false; end

    % ================= 5. 轴框识别（多种真实情形） =================
    cases = {};

    % (a) 干净的单框
    I2 = 255*ones(400, 600, 3, 'uint8');
    I2(50, 100:500, :) = 0; I2(350, 100:500, :) = 0;
    I2(50:350, 100, :) = 0; I2(50:350, 500, :) = 0;
    cases{end+1} = struct('name','干净单框', 'img',I2, ...
        'exp',[50 350 100 500], 'tol',3);

    % (b) 浅灰背景（很多扫描件/截图如此），框线是深灰
    I3 = uint8(238*ones(400, 600, 3));
    I3(50, 100:500, :) = 60; I3(350, 100:500, :) = 60;
    I3(50:350, 100, :) = 60; I3(50:350, 500, :) = 60;
    cases{end+1} = struct('name','浅灰背景', 'img',I3, ...
        'exp',[50 350 100 500], 'tol',3);

    % (c) 面板图：大画布上一个小面板，外围还有文字类黑块
    I4 = 255*ones(600, 900, 3, 'uint8');
    I4(200, 300:600, :) = 0; I4(450, 300:600, :) = 0;
    I4(200:450, 300, :) = 0; I4(200:450, 600, :) = 0;
    I4(20:40, 50:400, :) = 0;      % 页眉横条（干扰）
    I4(560:580, 50:400, :) = 0;    % 页脚横条（干扰）
    cases{end+1} = struct('name','面板+页眉页脚干扰', 'img',I4, ...
        'exp',[200 450 300 600], 'tol',3);

    % (d) 只有坐标轴线、没有完整矩形框（常见于只画 L 形的图）
    I5 = 255*ones(400, 600, 3, 'uint8');
    I5(350, 100:500, :) = 0;                   % X 轴
    I5(50:350, 100, :) = 0;                    % Y 轴
    try
        ax5 = curveTools('detectaxes', I5);
        okL = true;   % 只要不崩、给出合理范围就算通过（这种图必须手动画框）
        fprintf('L 形轴（无上/右边框）: 给出 top=%d bottom=%d left=%d right=%d -> 不崩溃即可\n', ...
            round(ax5.rowTop), round(ax5.rowBottom), round(ax5.colLeft), round(ax5.colRight));
    catch ME
        okL = false;
        fprintf('L 形轴: 崩溃了（%s）-> FAIL\n', ME.message);
    end
    if ~okL, pass = false; end

    for k = 1:numel(cases)
        cs = cases{k};
        axk = curveTools('detectaxes', cs.img);
        got = [axk.rowTop axk.rowBottom axk.colLeft axk.colRight];
        okk = all(abs(got - cs.exp) <= cs.tol);
        fprintf('轴框识别 %-18s: %s (期望 %s) -> %s\n', cs.name, ...
            mat2str(round(got)), mat2str(cs.exp), tern(okk,'OK','FAIL'));
        if ~okk, pass = false; end
    end

    % ================= 汇总 =================
    fprintf('\n');
    if pass
        fprintf('===== 自检全部通过 =====\n');
    else
        fprintf('===== 自检失败，见上面 !! 标记 =====\n');
    end
end

function s = tern(c, a, b)
    if c, s = a; else, s = b; end
end

function cal2 = calWithMask(cal, mask)
% 归约时把掩膜一起传进去，才能取每列的质心中心线
    cal2 = cal;
    cal2.mask = mask;
end
