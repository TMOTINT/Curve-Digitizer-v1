function digitizer_app
%DIGITIZER_APP  曲线数字化图形界面。
%   digitizer_app
%   流程：载入单幅图片、确认轴框、标定、提取、叠加核对、导出。
%   点击取点通过 uiaxes 事件完成。
%   运行环境和功能限制见 README.md。

    here = fileparts(mfilename('fullpath'));
    % 自动切到本文件夹：用户不必先 cd。只有当当前目录里没有 data/ 时才切，
    % 避免把用户已经摆好的工作目录顶掉。
    if ~exist(fullfile(pwd,'data'),'dir') && exist(fullfile(here,'data'),'dir')
        cd(here);
    end
    addpath(genpath(fullfile(here,'tools')));
    rehash;

    % ================= 状态 =================
    STKEY = 'CurveDigitizerState';
    ST = struct('imageFile','', 'I0',[], 'I',[], 'cropRect',[], ...
                'ax',[], 'cal',[], 'lab',[], 'curves',[], 'outPrefix','', ...
                'mode','idle', 'picks',zeros(0,2), 'hover',[NaN NaN]);

    % ================= 主窗口 =================
    fig = uifigure('Name','曲线数字化工具  Curve Digitizer', ...
                   'Position',[60 50 1380 880], 'Color',[0.96 0.965 0.97]);
    setappdata(fig, STKEY, ST);

    root = uigridlayout(fig, [2 3]);
    % 第 3 列只给底部"完成选择"按钮用；顶行跨前两列
    root.ColumnWidth = {336, '1x', 120};
    root.RowHeight   = {'1x', 30};
    root.Padding     = [8 8 8 8];
    root.ColumnSpacing = 8; root.RowSpacing = 6;

    % ---------------- 左列：控制 ----------------
    % 固定控件行高，为底部日志保留空间。
    leftCol = uigridlayout(root, [4 1]);
    leftCol.Layout.Row = 1; leftCol.Layout.Column = 1;
    leftCol.RowHeight = {'fit', 'fit', 'fit', '1x'};
    leftCol.Padding = [0 0 0 0]; leftCol.RowSpacing = 6;

    % 卡片1 图片
    p1 = uipanel(leftCol,'Title',' 1. 图片 ','FontSize',12,'FontWeight','bold');
    g1 = uigridlayout(p1,[3 1]); g1.RowHeight={18,26,26};
    g1.Padding=[8 6 8 6]; g1.RowSpacing=3;
    lblImg = uilabel(g1,'Text','未载入图片','FontSize',11,'FontColor',[0.45 0.45 0.5]);
    lblImg.Layout.Row=1;
    bPng = uibutton(g1,'Text','载入图片（用完整图，不需节选）','FontSize',11, ...
        'ButtonPushedFcn',@(s,e) onPickImage());
    bPng.Layout.Row=2;
    bPdf = uibutton(g1,'Text','从 PDF 抽取矢量曲线','FontSize',11, ...
        'ButtonPushedFcn',@(s,e) onPickPdf());
    bPdf.Layout.Row=3;

    % 卡片2 坐标轴
    p2 = uipanel(leftCol,'Title',' 2. 坐标轴 ','FontSize',12,'FontWeight','bold');
    g2 = uigridlayout(p2,[3 1]); g2.RowHeight={26,26,18};
    g2.Padding=[8 6 8 6]; g2.RowSpacing=3;
    bAx = uibutton(g2,'Text','确认坐标轴框','FontSize',11,'ButtonPushedFcn',@(s,e) onAxes());
    bAx.Layout.Row=1;
    bCal = uibutton(g2,'Text','标定（只填坐标范围）','FontSize',11, ...
        'ButtonPushedFcn',@(s,e) startCalibPick());
    bCal.Layout.Row=2;
    lblCal = uilabel(g2,'Text','尚未标定','FontSize',11,'FontColor',[0.45 0.45 0.5], ...
        'WordWrap','on');
    lblCal.Layout.Row=3;

    % 卡片3 数据系列
    % 曲线名称和单位在导出时手工填写。
    p3 = uipanel(leftCol,'Title',' 3. 数据系列 ','FontSize',12,'FontWeight','bold');
    g3 = uigridlayout(p3,[5 1]); g3.RowHeight={26,26,18,26,110};
    g3.Padding=[8 6 8 6]; g3.RowSpacing=3;
    bCur = uibutton(g3,'Text','自动分离曲线','FontSize',11,'ButtonPushedFcn',@(s,e) onCurves());
    bCur.Layout.Row=1;
    lblCur = uilabel(g3,'Text','曲线：0 条','FontSize',11,'FontColor',[0.45 0.45 0.5]);
    lblCur.Layout.Row=2;
    lblVerdict = uilabel(g3,'Text','质量：—','FontSize',11,'FontColor',[0.45 0.45 0.5]);
    lblVerdict.Layout.Row=3;
    bVer = uibutton(g3,'Text','重叠验证（原图 + 提取曲线）','FontSize',11, ...
        'ButtonPushedFcn',@(s,e) onVerify());
    bVer.Layout.Row=4;
    % 表格给固定高度，别用 '1x'（会被拉伸并挤掉下面内容）
    tbl = uitable(g3,'ColumnName',{'#','点数','名称'},'ColumnWidth',{34,48,'1x'}, ...
        'RowName',[],'FontSize',11);
    tbl.Layout.Row=5;      % 网格只有 5 行；写 7 会被静默丢弃，表格就不显示了

    % 卡片4 导出与工具
    p4 = uipanel(leftCol,'Title',' 4. 导出与工具 ','FontSize',12,'FontWeight','bold');
    g4 = uigridlayout(p4,[5 1]); g4.RowHeight={30,26,26,26,'1x'};
    g4.Padding=[8 6 8 6]; g4.RowSpacing=3;
    bExp = uibutton(g4,'Text','导出数据 (CSV / Excel / MAT)','FontSize',11, ...
        'FontWeight','bold','BackgroundColor',[0.78 0.92 0.78], ...
        'ButtonPushedFcn',@(s,e) onExport());
    bExp.Layout.Row=1;
    bTest = uibutton(g4,'Text','环境自检 / 清空日志','FontSize',11, ...
        'ButtonPushedFcn',@(s,e) onSelfTest());
    bTest.Layout.Row=2;
    % 点拟合曲线（fig3B/3C/3E）用：稳健局部二次拟合，去掉标记点/误差棒造成的局部起伏
    bFit = uibutton(g4,'Text','平滑拟合（仅 fig3B/3C）','FontSize',11, ...
        'ButtonPushedFcn',@(s,e) onFit());
    bFit.Layout.Row=3;
    % 可选项：剔除"带短横线的大点"（标记点/误差棒帽）所在列的测量
    bArt = uibutton(g4,'Text','剔除大点影响：关','FontSize',11, ...
        'ButtonPushedFcn',@(s,e) onToggleArt());
    bArt.Layout.Row=4;
    logBox = uitextarea(g4,'Editable','off','FontSize',10,'Value',{'就绪。'});
    logBox.Layout.Row=5;

    % ---------------- 右列：预览 ----------------
    pPrev = uipanel(root,'Title',' 预览（取点就在这里点击）','FontSize',13,'FontWeight','bold');
    pPrev.Layout.Row=1; pPrev.Layout.Column=[2 3];
    gp = uigridlayout(pPrev,[3 1]); gp.Padding=[4 4 4 4];
    gp.RowHeight={30,40,'1x'};
    verifyBar=uigridlayout(gp,[1 5]);verifyBar.Layout.Row=1;
    verifyBar.ColumnWidth={90,125,95,90,'1x'};verifyBar.Padding=[0 0 0 0];
    uibutton(verifyBar,'Text','重叠验证','Tag','OverlayVerify', ...
        'ButtonPushedFcn',@(s,e) onVerify());
    chkOverlay=uicheckbox(verifyBar,'Text','显示提取曲线','Value',true, ...
        'Tag','OverlayToggle','ValueChangedFcn',@(s,e) onOverlayToggle());
    chkError=uicheckbox(verifyBar,'Text','显示误差','Value',false, ...
        'Tag','ErrorToggle','ValueChangedFcn',@(s,e) onErrorToggle());
    uibutton(verifyBar,'Text','数据曲线','Tag','DataPlot', ...
        'ButtonPushedFcn',@(s,e) onDataPlot());
    uilabel(verifyBar,'Text','青色细线为提取结果；可缩放查看','FontSize',11);
    lblError=uilabel(gp,'Text','图像贴线偏差（像素）：勾选“显示误差”查看', ...
        'Tag','ErrorSummary','WordWrap','on','FontSize',11);lblError.Layout.Row=2;
    axP = uiaxes(gp,'Tag','OverlayAxes');axP.Layout.Row=3;
    axP.XTick=[]; axP.YTick=[]; axP.Box='on';
    axP.ButtonDownFcn = @(s,e) onAxesClick();
    title(axP,'尚未载入图片');

    % ---------------- 提示条 + 完成按钮 ----------------
    root.ColumnWidth = {336, '1x', 120};
    hint = uilabel(root,'Text','就绪','FontSize',12,'FontWeight','bold', ...
        'FontColor',[1 1 1],'BackgroundColor',[0.28 0.35 0.45], ...
        'HorizontalAlignment','left');
    hint.Layout.Row=2; hint.Layout.Column=[1 2];
    bDone = uibutton(root,'Text','完成选择','Enable','off', ...
        'FontWeight','bold','BackgroundColor',[0.85 0.93 0.85], ...
        'ButtonPushedFcn',@(s,e) finishSeeds());
    bDone.Layout.Row=2; bDone.Layout.Column=3;

    % ================= 内部工具 =================
    function S = st(), S = getappdata(fig, STKEY); end
    function setS(S)
        setappdata(fig, STKEY, S);
        refreshSummary(S);
    end
    function say(msg, kind)
        if nargin<2, kind='info'; end
        switch kind
            case 'ok',   bg=[0.16 0.50 0.24];
            case 'warn', bg=[0.72 0.50 0.10];
            case 'err',  bg=[0.70 0.20 0.20];
            case 'act',  bg=[0.15 0.40 0.70];
            otherwise,   bg=[0.28 0.35 0.45];
        end
        hint.Text = msg; hint.BackgroundColor = bg;
        v = logBox.Value; if ischar(v), v={v}; end
        v{end+1} = sprintf('[%s] %s', char(datetime('now','Format','HH:mm:ss')), msg);
        if numel(v)>400, v=v(end-399:end); end
        logBox.Value = v;
        % 同时写入 _app_log.txt：方便事后回看、也方便把日志贴出来
        try
            lf = fullfile(fileparts(mfilename('fullpath')), '_app_log.txt');
            fid = fopen(lf, 'a', 'n', 'UTF-8');
            if fid > 0
                fprintf(fid, '[%s] %s\n', char(datetime('now','Format','yyyy-MM-dd HH:mm:ss')), msg);
                fclose(fid);
            end
        catch
        end
        drawnow limitrate;
    end
    function refreshSummary(S)
        if isempty(S.imageFile)
            lblImg.Text = '未载入图片';
        else
            [~,nm,ex] = fileparts(S.imageFile);
            lblImg.Text = sprintf('%s%s  (%d×%d)', nm, ex, size(S.I,2), size(S.I,1));
        end
        if ~okCal(S.cal)
            if isempty(S.ax)
                lblCal.Text = '轴框未确认';
            else
                lblCal.Text = sprintf('轴框 %d×%d，待标定', ...
                    round(S.ax.colRight-S.ax.colLeft), round(S.ax.rowBottom-S.ax.rowTop));
            end
        else
            % 标定信息里显式写出"用的是什么范围"，方便一眼核对
            ruleTxt = '';
            if isfield(S.cal,'method') && strcmp(S.cal.method,'corner-values')
                if isfield(S.cal,'cornerVal') && numel(S.cal.cornerVal)==4
                    cv = S.cal.cornerVal;
                    ruleTxt = sprintf('（左下 %.4g, %.4g → 右上 %.4g, %.4g）', ...
                        cv(1), cv(2), cv(3), cv(4));
                end
            elseif isfield(S.cal,'method') && strcmp(S.cal.method,'manual-ticks')
                ruleTxt = '（刻度拟合）';
            end
            if isfield(S.cal,'gridPx') && numel(S.cal.gridPx)==2
                lblCal.Text = sprintf(['X [%g, %g]  Y [%g, %g]%s\n' ...
                    '一格 = %.4g px（X）  %.4g px（Y）'], ...
                    S.cal.xlim, S.cal.ylim, ruleTxt, ...
                    S.cal.gridPx(1), S.cal.gridPx(2));
            else
                lblCal.Text = sprintf('X [%g, %g]   Y [%g, %g]%s', ...
                    S.cal.xlim, S.cal.ylim, ruleTxt);
            end
        end
        if ~isfield(S,'verdict') || isempty(S.verdict)
            lblVerdict.Text = '质量：—';
        elseif strcmp(S.verdict,'suspect')
            lblVerdict.Text = '质量：⚠ 有曲线偏差超容差';
            lblVerdict.FontColor = [0.75 0.35 0.10];
        else
            lblVerdict.Text = '质量：正常';
            lblVerdict.FontColor = [0.16 0.50 0.24];
        end
        lblCur.Text = sprintf('曲线：%d 条', numel(S.curves));
        if isempty(S.curves)
            tbl.Data = {};
        else
            d = cell(numel(S.curves),3);
            for k=1:numel(S.curves)
                nm = S.curves(k).name;
                if isempty(nm), nm = sprintf('curve%d',k); end
                d{k,1}=k; d{k,2}=numel(S.curves(k).X); d{k,3}=nm;
            end
            tbl.Data = d;
        end
    end
    function showImg(I, ttl)
        chkError.Value=false;
        if isappdata(fig,'CurveDigitizerErrors'),rmappdata(fig,'CurveDigitizerErrors');end
        lblError.Text='图像贴线偏差（像素）：勾选“显示误差”查看';
        cla(axP);
        hIm = image(axP, I);
        % 关键：uiaxes 上点击图像时，事件命中的是 image 对象而不是 axes，
        % 所以回调必须挂在 image 上；只设 axes.ButtonDownFcn 会点不动。
        hIm.ButtonDownFcn = @(s,e) onAxesClick();
        axP.ButtonDownFcn = @(s,e) onAxesClick();
        axP.YDir='reverse'; axis(axP,'image');
        axP.XTick=[]; axP.YTick=[];
        if nargin>=2, title(axP, ttl, 'Interpreter','none'); end
        drawnow limitrate;
    end
    function boxOverlay(ax, col)
        if isempty(ax), return; end
        if nargin<2, col=[0 0.65 1]; end
        hold(axP,'on');
        plot(axP,[ax.colLeft ax.colRight ax.colRight ax.colLeft ax.colLeft], ...
                  [ax.rowTop ax.rowTop ax.rowBottom ax.rowBottom ax.rowTop], ...
                  '-','Color',col,'LineWidth',1.6);
        hold(axP,'off'); drawnow limitrate;
    end
    function markPicks(pts, nm)
        hold(axP,'on');
        for k=1:size(pts,1)
            plot(axP, pts(k,1), pts(k,2), 'o', 'MarkerSize',11, ...
                 'LineWidth',2, 'Color',[0.95 0.1 0.1]);
            text(axP, pts(k,1)+8, pts(k,2), sprintf('%s%d', nm, k), ...
                 'Color',[0.85 0 0], 'FontSize',12, 'FontWeight','bold');
        end
        hold(axP,'off');
        rehookImageClicks();     % 叠加绘图会盖住 image 的回调，必须重挂
        drawnow limitrate;
    end
    function drawCandidates(cand)
        hold(axP,'on');
        for k=1:numel(cand)
            plot(axP, cand(k).seed(1), cand(k).seed(2), 'o', 'MarkerSize',12, ...
                 'LineWidth',2, 'Color', cand(k).color/255);
            text(axP, cand(k).seed(1)+8, cand(k).seed(2), sprintf('%d',k), ...
                 'Color','k','FontSize',12,'FontWeight','bold');
        end
        hold(axP,'off');
        rehookImageClicks();
        drawnow limitrate;
    end
    function rehookImageClicks()
        % 给坐标轴里所有 image 对象重挂点击回调（hold on 绘图后仍需可点击）
        h = findobj(axP, 'Type','image');
        for q = 1:numel(h)
            h(q).ButtonDownFcn = @(s,e) onAxesClick();
        end
        axP.ButtonDownFcn = @(s,e) onAxesClick();
    end
    function ok = needImage(S)
        ok = ~isempty(S.I);
        if ~ok, uialert(fig,'请先载入图片（或从 PDF 抽取）。','提示'); end
    end

    % ---------- 取点：核心交互 ----------
    function beginPick(mode, prompt)
        S = st();
        S.mode = mode; S.picks = zeros(0,2);
        setS(S);
        updatePickUI();
        say(prompt, 'act');
    end
    % 让"完成选择"按钮在两种"自由点够为止"的模式下可用：seed（点曲线种子）和 ticks（点刻度）。
    function updatePickUI()
        S = st();
        wantDone = any(strcmp(S.mode, {'seed','ticks'}));
        bDone.Enable = tern(wantDone, 'on', 'off');
        if strcmp(S.mode,'ticks')
            bDone.Text = '完成刻度点击';
        else
            bDone.Text = '完成选择';
        end
    end
    function onAxesClick()
        S = st();
        if strcmp(S.mode,'idle'), return; end
        cp = axP.CurrentPoint;              % 图像坐标（已按 YDir 处理）
        p = [cp(1,1), cp(1,2)];
        S.picks(end+1,:) = p;
        setS(S);
        markPicks(S.picks, 'P');
        n = size(S.picks,1);
        switch S.mode
            case 'panel'
                if n==1
                    say('已记下左上角，请点击右下角…','act');
                else
                    finishPanel(); 
                end
            case 'axbox'
                if n==1
                    say('已记下左上角，请点击右下角…','act');
                else
                    finishAxBox();
                end
            case 'calib2'
                % 兼容旧状态（正常流程不会再进入这里）
                finishTicks();
            case 'ticks'
                nX = size(S.picks,1);
                if nX==1
                    say('已点 X 轴第 1 个刻度。继续点这个轴上其它刻度，或点"完成刻度点击"。','act');
                else
                    say(sprintf('已点 %d 个刻度。可继续点，或点"完成刻度点击"填入数值。', nX),'act');
                end
                updatePickUI();
            case 'seed'
                say(sprintf('已点 %d 个曲线种子点。继续点，或按"完成"按钮结束。', n), 'act');
        end
    end
    function finishPanel()
        S = st(); p = S.picks;
        S.mode='idle'; setS(S);
        x0 = max(1,round(min(p(:,1)))); x1 = min(size(S.I0,2),round(max(p(:,1))));
        y0 = max(1,round(min(p(:,2)))); y1 = min(size(S.I0,1),round(max(p(:,2))));
        if x1-x0 < 30 || y1-y0 < 30
            uialert(fig,'框太小，未采用（仍使用整幅图）','提示');
            say('框太小，已忽略','warn'); showImg(S.I,'未裁剪'); return;
        end
        S.cropRect=[x0 y0 x1 y1];
        S.I = S.I0(y0:y1, x0:x1, :);
        S.ax=[]; S.cal=[]; S.curves=[];
        setS(S);
        showImg(S.I, sprintf('面板 x%d-%d, y%d-%d', x0,x1,y0,y1));
        say(sprintf('已裁剪面板：%d × %d px。下一步点"③ 确认坐标轴框"。', ...
            size(S.I,2), size(S.I,1)), 'ok');
    end
    function finishAxBox()
        S = st(); p = S.picks;
        S.mode='idle';
        S.ax = struct('rowTop',min(p(:,2)),'rowBottom',max(p(:,2)), ...
                      'colLeft',min(p(:,1)),'colRight',max(p(:,1)));
        setS(S);
        showImg(S.I,'坐标轴框已设（青框）'); boxOverlay(S.ax,[0 0.7 0.7]);
        say('轴框已确认（手动）。下一步点"④ 标定"。','ok');
    end
    function finishTicks()
        % 手动标定的推荐入口：用户在图上点出【各自知道数值的刻度位置】，
        % 然后一次性填入这些刻度对应的数值，程序对每个轴做最小二乘直线拟合。
        %
        % 为什么不能像旧版那样"点一个刻度 + 填轴框边界值"：轴框边界（绘图区
        % 四边）绝大多数情况下【不等于】坐标范围（例如 X 轴画到 6 但数据只到
        % 4.6，轴框左边还留了一点余量），把边界当成 0/6 会让整条标定线平移，
        % 这正是"标定不准确"的根因。用真实刻度做拟合则不依赖任何边界假设。
        S = st(); p = S.picks; S.mode='idle'; setS(S); updatePickUI();
        if isempty(p)
            say('你没有点任何刻度，标定未改变。请重新点"④ 标定"。','warn'); return;
        end
        nP = size(p,1);
        % 至少 4 个点（每轴 2 个）才能定出斜率与截距；点更多则拟合更稳。
        if nP < 4
            uialert(fig, sprintf(['只点了 %d 个刻度点，不足以标定。\n\n' ...
                '至少要点 4 个：X 轴上 2 个以上不同刻度 + Y 轴上 2 个以上不同刻度。\n' ...
                '（刻度线密时点 3~4 个，拟合会更稳。）'], nP), '刻度点不够');
            say(sprintf('刻度点只有 %d 个，需要至少 4 个（X 轴≥2，Y 轴≥2）', nP),'err');
            return;
        end

        % 判定这批点属于哪个轴：
        %  - 若某个轴已经标定过（另一轴还没），这批点就整体归给还没标定的那个轴；
        %  - 否则按"前一半 X、后一半 Y"的约定切分（这也是界面提示的规则）。
        hasX = ~isempty(S.cal) && isstruct(S.cal) && isfield(S.cal,'xFromPx');
        hasY = ~isempty(S.cal) && isstruct(S.cal) && isfield(S.cal,'yFromPx');
        if hasX && ~hasY
            axLabels = repmat({'Y'}, 1, nP);
        elseif hasY && ~hasX
            axLabels = repmat({'X'}, 1, nP);
        else
            nX = floor(nP/2);
            axLabels = [repmat({'X'},1,nX), repmat({'Y'},1,nP-nX)];
        end

        prompts = cell(1,nP); defs = cell(1,nP);
        for k = 1:nP
            prompts{k} = sprintf('%s 轴刻度 %d：图上像素 (%g, %g) 处的刻度值 =', ...
                axLabels{k}, k, p(k,1), p(k,2));
            if hasX && strcmp(axLabels{k},'X')
                defs{k} = num2str(S.cal.xFromPx(p(k,1)),'%.6g');
            elseif hasY && strcmp(axLabels{k},'Y')
                defs{k} = num2str(S.cal.yFromPx(p(k,2)),'%.6g');
            else
                defs{k} = '0';
            end
        end
        a = inputdlg(prompts, ...
            sprintf(['第④步：填入这 %d 个刻度各自的数值   ' ...
                     '（本次按 X×%d + Y×%d 解释）'], nP, ...
                     sum(strcmp(axLabels,'X')), sum(strcmp(axLabels,'Y'))), 1, defs);
        if isempty(a), say('标定已取消（刻度点仍保留，可再点"完成刻度点击"）','warn'); return; end
        v = str2double(a);
        if any(isnan(v))
            uialert(fig,'有非数字或空输入，标定未生效','提示'); say('标定输入无效','err'); return;
        end
        iX = strcmp(axLabels,'X');
        if any(iX)
            if applyTickCalib('X', p(iX,:), v(iX)), return; end
        end
        if any(~iX)
            applyTickCalib('Y', p(~iX,:), v(~iX));
        end
    end

    % 对单个轴做最小二乘标定：像素坐标 -> 数据值。
    % isnan 的返回值表示"该轴标定失败"，外层据此给出针对性提示。
    function bad = applyTickCalib(axName, pts, vals)
        S = st(); bad = false;
        % 用副本累积两个轴的结果：先标 X 再标 Y，或反过来，都能拼成完整标定。
        cal = S.cal;
        if isempty(cal) || ~isstruct(cal)
            cal = struct('nTickX',0,'nTickY',0,'method','','confidence',0, ...
                         'ok',false,'xlim',[NaN NaN],'ylim',[NaN NaN], ...
                         'xFromPx',@(q) NaN,'yFromPx',@(q) NaN);
        end
        if ~isfield(cal,'nTickX') || isempty(cal.nTickX), cal.nTickX = 0; end
        if ~isfield(cal,'nTickY') || isempty(cal.nTickY), cal.nTickY = 0; end
        if strcmp(axName,'X')
            px = pts(:,1); other = pts(:,2);
        else
            px = pts(:,2); other = pts(:,1);   % 行号越大值越小，斜率天然为负
        end
        if numel(unique(px)) < 2 || max(px)-min(px) < 3
            uialert(fig, sprintf(['%s 轴上这几个刻度点的像素位置几乎重合' ...
                '（跨度仅 %.1f px），无法定出比例。\n\n请重新点"④ 标定"，' ...
                '在这个轴上点相隔较远的 2~4 个刻度。'], axName, max(px)-min(px)), '标定失败');
            say(sprintf('%s 轴刻度点太集中，标定未生效', axName),'err'); bad = true; return;
        end
        if numel(unique(vals)) < 2
            uialert(fig, sprintf('%s 轴填的数值全相同，无法标定。', axName), '标定失败');
            say(sprintf('%s 轴刻度值全相同', axName),'err'); bad = true; return;
        end

        % 最小二乘直线：val = a*px + b
        X = [px, ones(numel(px),1)];
        cf = X \ vals;
        aSlope = cf(1); bInt = cf(2);
        fit = X*cf;
        resid = vals - fit;
        rms = sqrt(mean(resid.^2));
        span = max(vals) - min(vals);
        % 明显离群（超过量程 1.5% 且超过 3 倍 RMS）的刻度点剔除后重拟合
        drop = false(numel(vals),1);
        if numel(vals) >= 4 && span > 0
            drop = abs(resid) > max(3*rms, 0.015*span);
            if any(drop) && sum(~drop) >= 2
                X2 = X(~drop,:);
                cf = X2 \ vals(~drop);
                aSlope = cf(1); bInt = cf(2);
                fit = X*cf; resid = vals - fit; rms = sqrt(mean(resid(~drop).^2));
                say(sprintf('%s 轴：有 %d 个刻度点偏离拟合线较多，已自动剔除（多半是点歪了）。', ...
                    axName, sum(drop)),'warn');
            end
        end
        se = sqrt(sum(resid.^2)/max(1,numel(vals)-2));
        sc = abs(aSlope)*max(other) + abs(bInt);
        if se > max(1e-9, 0.003*sc)
            say(sprintf(['%s 轴标定一致性一般：残差 RMS = %.4g（约为刻度值量级的 %.2f%%）。' ...
                '建议重新点刻度，或把刻度点分布得更开。'], axName, rms, 100*se/max(sc,eps)), 'warn');
        end

        if strcmp(axName,'X')
            cal.xFromPx = @(q) aSlope*q + bInt;
            cal.xlim = [aSlope*S.ax.colLeft + bInt, aSlope*S.ax.colRight + bInt];
            cal.nTickX = numel(vals);
        else
            cal.yFromPx = @(q) aSlope*q + bInt;
            cal.ylim = [aSlope*S.ax.rowBottom + bInt, aSlope*S.ax.rowTop + bInt];
            cal.nTickY = numel(vals);
        end
        cal.method = 'manual-ticks'; cal.confidence = 1;
        if ~cal.nTickX || ~cal.nTickY
            % 只完成了一个轴，先记账，等另一个轴标定好再一起报告结果。
            cal.ok = false;
            S.cal = cal; setS(S);
            say(sprintf(['%s 轴标定已记录（%d 个刻度点）。现在请重新点"④ 标定"，' ...
                '在另一个轴上点 2~4 个刻度。'], axName, numel(vals)), 'act');
            return;
        end
        cal.ok = true; S.cal = cal; setS(S);
        say(sprintf(['标定完成（刻度拟合）：X [%g, %g]（%d 个刻度点）  ' ...
            'Y [%g, %g]（%d 个刻度点）。下一步点"⑥ 分离曲线"。'], ...
            cal.xlim, cal.nTickX, cal.ylim, cal.nTickY), 'ok');
        [S, mU] = askUnits(S); setS(S); if ~isempty(mU), say(mU,'ok'); end
    end

    % ================= 回调 =================
    function onPickImage()
        S = st();
        [f,p] = uigetfile({'*.png;*.jpg;*.jpeg;*.tif;*.tiff;*.bmp','图片文件'},'选择图片');
        if isequal(f,0), say('已取消载入'); return; end
        fn = fullfile(p,f);
        try
            I = imread(fn);
        catch ME
            uialert(fig,ME.message,'读取失败'); say('读取失败','err'); return;
        end
        I = toRGB(I);
        S.imageFile=fn; S.I0=I; S.I=I;
        S.cropRect=[1 1 size(I,2) size(I,1)];
        [~,nm] = fileparts(fn);
        S.outPrefix = fullfile(p,nm);
        S.ax=[]; S.cal=[]; S.lab=[]; S.curves=[]; S.mode='idle'; S.unitAsked=false;
        setS(S);
        showImg(S.I, sprintf('%s  (%d×%d)', nm, size(I,2), size(I,1)));
        say(sprintf('已载入 %s（%d×%d）。多面板图请先在外部裁成单幅。', ...
            nm, size(I,2), size(I,1)), 'ok');
    end

    function onPickPdf()
        S = st();
        [f,p] = uigetfile({'*.pdf','PDF 文件'},'选择 PDF');
        if isequal(f,0), say('已取消'); return; end
        pdf = fullfile(p,f);
        a = inputdlg({'页码（从 1 开始）:'},'PDF 矢量抽取',1,{'1'});
        if isempty(a), return; end
        pno = str2double(a{1});
        if isnan(pno)||pno<1, uialert(fig,'页码无效','提示'); return; end
        [stt,~] = system('python -c "import pymupdf"');
        if stt~=0
            uialert(fig, sprintf(['未检测到 Python 的 pymupdf 模块。\n\n' ...
                '请在系统命令行执行：\n    pip install pymupdf\n\n' ...
                '（或改用"载入图片"做图像数字化）']),'缺少依赖');
            say('缺少 pymupdf，PDF 抽取不可用','err'); return;
        end
        say(sprintf('正在抽取 %s 第 %d 页…', f, pno), 'act');
        d = uiprogressdlg(fig,'Title','抽取中','Indeterminate','on','Message','读取矢量路径…');
        outPre = fullfile(p, sprintf('pdf_p%d', pno));
        try
            res = extract_pdf_figure(pdf, pno, outPre, struct('autoConfirm',true));
            try, close(d); catch, end   % 不用 isvalid：它不是基础 MATLAB 函数
        catch ME
            try, close(d); catch, end   % 不用 isvalid：它不是基础 MATLAB 函数
            uialert(fig,ME.message,'PDF 抽取失败');
            say(sprintf('PDF 抽取失败：%s', ME.message),'err'); return;
        end
        if ~res.isVector
            uialert(fig,'该页没有矢量曲线（图是位图），请改用"载入图片"。','提示');
            say('该页无矢量曲线','warn'); return;
        end
        I = toRGB(imread(res.png));
        S.imageFile=res.png; S.I0=I; S.I=I;
        S.cropRect=[1 1 size(I,2) size(I,1)];
        S.outPrefix=outPre;
        if ~isempty(res.curves)
            S.curves = res.curves;
            S.ax = struct('rowTop',1,'rowBottom',size(I,1),'colLeft',1,'colRight',size(I,2));
            if isfield(res,'cal') && ~isempty(res.cal), S.cal = res.cal; end
            if isfield(res,'axis') && ~isempty(res.axis)
                S.lab = struct('axis', struct( ...
                    'x',struct('title',res.axis.xTitle,'unit',res.axis.xUnit), ...
                    'y',struct('title',res.axis.yTitle,'unit',res.axis.yUnit)), ...
                    'legend',struct([]),'units',{{}},'notes',{{}});
            end
        end
        setS(S);
        showImg(S.I, sprintf('PDF 第 %d 页（矢量已抽出）', pno));
        say(sprintf('矢量抽取完成，得到 %d 条曲线。可直接点"⑦ 预览验证"或"⑧ 导出"。', ...
            numel(S.curves)),'ok');
    end

    function startPanelPick()
        % 使用完整的单幅图片。
        % 保留本函数只为兼容旧调用；现在它只做一次"确认用整图"的提示。
        S = st();
        if ~needImage(S), return; end
        if isempty(S.I0), S.I0 = S.I; setS(S); end
        S.cropRect = [1 1 size(S.I,2) size(S.I,1)];
        setS(S);
        showImg(S.I, '使用完整图片（不再节选）');
        say('已按"完整图片"模式工作：不再需要框选面板。若图是多面板拼版，请先在外部裁好单幅。','ok');
    end

    function onAxes()
        S = st();
        if ~needImage(S), return; end
        axAuto=[]; okAuto=false;
        try
            axAuto = curveTools('detectaxes', S.I);
            okAuto = ~(axAuto.rowTop<=2 && axAuto.colLeft<=2 && ...
                       axAuto.rowBottom>=size(S.I,1)-1 && axAuto.colRight>=size(S.I,2)-1);
        catch ME
            say(sprintf('自动识别轴框失败：%s', ME.message),'warn');
        end
        if okAuto
            showImg(S.I,'建议的坐标轴框（青框）'); boxOverlay(axAuto,[0 0.7 0.7]);
            a = uiconfirm(fig,'接受青框作为坐标轴吗？','第③步 确认轴框', ...
                'Options',{'接受','手动画框'},'DefaultOption',1,'CancelOption',2);
            if strcmp(a,'接受')
                S.ax = axAuto; setS(S);
                say('轴框已确认（自动识别）。下一步点"④ 标定"。','ok'); return;
            end
        else
            uialert(fig,'未能自动识别轴框，请在预览区手动画框（点左上角、再点右下角）。', ...
                '手动画框','Icon','info');
        end
        beginPick('axbox','请在预览区点击坐标轴框的【左上角】');
    end

    function startCalibPick()
        S = st();
        if ~needImage(S), return; end
        if isempty(S.ax), uialert(fig,'请先完成"③ 确认坐标轴框"','提示'); return; end

        % ---- 先选方式：范围法（最省事，推荐）、刻度拟合法、自动读刻度 ----
        a = uiconfirm(fig, sprintf(['标定方式：\n\n' ...
            '· 只填坐标范围（推荐）：你只填图上的 4 个数字 ——\n' ...
            '     左下角的 X、Y 值 + 右上角的 X、Y 值\n' ...
            '   像素坐标由程序自己读，你一个像素都不用量。\n' ...
            '   例：Fig.3A 填 左下角 (0, 0)、右上角 (1.2, 630)。\n\n' ...
            '· 刻度拟合：在图上点 2~4 个刻度线并逐个填数值，做最小二乘拟合。' ...
            '适合坐标范围不好确定、或网格不均匀的图。\n\n' ...
            '· 自动读刻度：尝试 OCR 读图上的刻度文字。对不同排版/字号不一定准。']), ...
            '第④步 标定', ...
            'Options', {'只填坐标范围（推荐）','刻度拟合法','自动读刻度'}, ...
            'DefaultOption', 1, 'CancelOption', 1);
        if isempty(a), say('已取消'); return; end

        if startsWith(a, '刻度拟合')
            % ---- 手动标定：点真实刻度（拟合）----
            showImg(S.I,'手动标定：依次点出各个【已知数值的刻度】位置');
            boxOverlay(S.ax,[0 0.7 0.7]);
            a3 = uiconfirm(fig, sprintf(['请点击图上刻度线的位置（不是刻度文字，是刻度线本身）：\n\n' ...
                '  1) 先在 X 轴上点 2~4 个刻度；\n' ...
                '  2) 再在 Y 轴上点 2~4 个刻度；\n' ...
                '  3) 点完后按右下角"完成刻度点击"，逐条填入这些刻度的数值。\n\n' ...
                '顺序约定：前一半算 X 轴，后一半算 Y 轴。\n' ...
                '点的刻度分布得越开、数目越多，标定越准（与轴框大小无关）。']), ...
                '第④步 手动标定', 'Options',{'开始点击','取消'}, ...
                'DefaultOption',1,'CancelOption',2);
            if ~strcmp(a3,'开始点击')
                say('已取消手动标定','warn'); return;
            end
            beginPick('ticks', '请点击 X 轴上第 1 个刻度线的位置（共点 2~4 个 X 刻度）');
            return;
        end

        % 注意：这里必须用 contains 而不是 startsWith。
        % 选项文字是"只填坐标范围（推荐）"，'范围'在中间，
        % startsWith 判断为 false —— 结果是三个分支全不命中，
        % 点完按钮什么都不发生（实测踩过这个坑）。
        if contains(a, '范围')
            % ================= 方式一（推荐）：只填横纵坐标范围 =================
            % 用户只抄图上的数字，一个像素都不用量。程序自己干三件事：
            %   1) 定位左下角交点与右上角（轴框的角）
            %   2) 量出该轴的刻度间距，用来核对"范围 ÷ 格数"是否自洽
            %   3) 按"角点的值 + 角点的像素"建立线性映射
            %
            % 为什么把锚点放在轴框的角上（而不是按刻度间距推）：
            % 轴框的范围就是用户在图上看到的范围，直接用它当锚点，
            % 不依赖"哪个刻度代表哪个数"的猜测，也不受自动量取误差影响。
            % 刻度间距只做自洽性核对：对不上就提示用户核对输入。
            [orgCol, orgRow, spX, spY, jr] = detectOriginAndGrid(S.I, S.ax);
            hasOrg = isfinite(orgCol) && isfinite(orgRow);

            % 角点像素（自动；量不到才需要用户在对话框里改）
            if hasOrg
                cL = orgCol; rB = orgRow;
            else
                cL = S.ax.colLeft; rB = S.ax.rowBottom;   % 退化为轴框左下角
            end
            cR = S.ax.colRight; rT = S.ax.rowTop;

            % 格数（用于自洽核对；只有轴框确实从刻度线起才准）
            nCellX = NaN; nCellY = NaN;
            if isfinite(spX) && spX > 1
                nCellX = (cR - cL) / spX;
            end
            if isfinite(spY) && spY > 1
                nCellY = (rB - rT) / spY;
            end
            xHint = tern(isfinite(nCellX), sprintf('轴框内约 %.1f 格', nCellX), '格数未知');
            yHint = tern(isfinite(nCellY), sprintf('轴框内约 %.1f 格', nCellY), '格数未知');

            % ---- 右上角的两个值：先试着用 OCR 读刻度给默认值 ----
            %   这是"肉眼无法判断最大值"的解法：很多图的轴框比标注范围更大
            %   （实测 Fig.3A 的 y 轴只标到 500，而轴框顶边对应约 575 nm）。
            %   程序读刻度数字 -> 最小二乘拟合 -> 外推到轴框边界，把结果填成
            %   默认值让你核对；读不出就留空（不阻断，照样能手填）。
            dX = ''; dY = ''; noteX = ''; noteY = '';
            try
                guess = calibrateFromLabels(S.I, S.ax);
            catch
                guess = [];
            end
            if ~isempty(guess) && guess.ok
                dX = sprintf('%.4g', guess.cal.xFromPx(cR));
                dY = sprintf('%.4g', guess.cal.yFromPx(rT));
                noteX = sprintf('\n    （已用 %d 个刻度 OCR 拟合，外推值 %.4g，可直接用）', ...
                    numel(guess.xTicks), guess.cal.xFromPx(cR));
                noteY = sprintf(['\n    （已用 %d 个刻度 OCR 拟合，外推值 %.4g）\n' ...
                    '     注意：它可能大于图上最大标注值 —— 轴框顶边常常高于最大刻度'], ...
                    numel(guess.yTicks), guess.cal.yFromPx(rT));
                say(sprintf(['刻度 OCR 成功：X 用 %d 个刻度、Y 用 %d 个刻度拟合，' ...
                    '外推到轴框边界得 右上 (%.4g, %.4g)'], ...
                    numel(guess.xTicks), numel(guess.yTicks), ...
                    guess.cal.xFromPx(cR), guess.cal.yFromPx(rT)), 'ok');
            end

            a2 = inputdlg({ ...
                sprintf('① 左下角的 X 值（图上标着，如 -0.2 或 0）\n    自动取的位置：像素列 %.0f', cL), ...
                sprintf('② 左下角的 Y 值（图上标着，如 0）\n    自动取的位置：像素行 %.0f', rB), ...
                sprintf('③ 右上角的 X 值（横轴最大刻度值，如 1.2）\n    对应轴框最右：像素列 %.0f（%s）%s', cR, xHint, noteX), ...
                sprintf('④ 右上角的 Y 值（纵轴顶部对应的值）\n    对应轴框最上：像素行 %.0f（%s）%s', rT, yHint, noteY)}, ...
                '第④步 标定：只填横纵坐标范围', 1, {'0','0',dX,dY});
            if isempty(a2), say('标定已取消','warn'); return; end
            v = str2double(a2);
            if any(isnan(v))
                uialert(fig, sprintf(['有非数字或空输入，标定未生效。\n\n' ...
                    '四个框都要填数字（照抄图上标的刻度值）：\n' ...
                    '  ① 左下角的 X 值   ② 左下角的 Y 值\n' ...
                    '  ③ 右上角的 X 值   ④ 右上角的 Y 值']), '提示');
                say('标定输入无效','err'); return;
            end
            x0 = v(1); y0 = v(2); x1 = v(3); y1 = v(4);
            if x1 == x0 || y1 == y0
                uialert(fig, sprintf(['横轴（或纵轴）的左右两个值相同，无法标定：\n' ...
                    '  X: %.4g -> %.4g\n  Y: %.4g -> %.4g\n\n' ...
                    '请填成图上真正的两端刻度值。'], x0, x1, y0, y1), '提示');
                say('标定输入无效（两端值相同）','err'); return;
            end
            scx = (x1 - x0) / (cR - cL);
            scy = (y1 - y0) / (rB - rT);
            if ~isfinite(scx) || ~isfinite(scy) || scx == 0 || scy == 0
                uialert(fig,'角点像素间距为 0，请先确认坐标轴框','提示');
                say('标定输入无效','err'); return;
            end

            cal = struct();
            cal.xFromPx = @(q) x0 + (q - cL) * scx;
            cal.yFromPx = @(q) y0 + (rB - q) * scy;
            cal.xlim = sort([cal.xFromPx(S.ax.colLeft), cal.xFromPx(S.ax.colRight)]);
            cal.ylim = sort([cal.yFromPx(S.ax.rowTop),  cal.yFromPx(S.ax.rowBottom)]);
            cal.method = 'corner-values'; cal.confidence = 1;
            cal.nTickX = 0; cal.nTickY = 0; cal.ok = true;
            % 一格 = 多少数值 / 多少像素（由范围与角点反算，供状态栏显示）
            cal.gridPx = [abs(1/scx), abs(1/scy)];
            cal.gridVal = [1, 1];
            cal.cornerPx = [cL rB cR rT];
            cal.cornerVal = [x0 y0 x1 y1];
            cal.originVal = [x0 y0];
            cal.cellRule = 'range';
            % ---- 自洽核对：角点算出的"每格数值" vs 自动量到的刻度间距 ----
            % 这是最有力的一条检查：两条完全独立的路径算同一个量 ——
            %   路径A：你填的两端值 ÷ 角点像素   -> 每格数值
            %   路径B：自动量到的"每格像素" × 路径A 的比例
            % 对得上（差异 < 4%）说明你填的范围与轴框边界一致；
            % 对不上就说明"轴框最右/最上"并不是你填那个值所在的位置
            % （图可能在轴框外还画了刻度），这时提醒你改右上角的数字。
            warnTxt = '';
            if isfinite(spX) && spX > 1
                perCell = abs(scx) * spX;      % 路径B：一格多少数值
                warnTxt = [warnTxt sanityNote(perCell, 'X', jr(1), ...
                    sprintf('自动量到一格约 %.1f px，据此一格 = %.4g', spX, perCell))];
            end
            if isfinite(spY) && spY > 1
                perCell = abs(scy) * spY;
                warnTxt = [warnTxt sanityNote(perCell, 'Y', jr(2), ...
                    sprintf('自动量到一格约 %.1f px，据此一格 = %.4g', spY, perCell))];
            end
            S.cal = cal; setS(S);
            say(sprintf(['标定完成（只用了图上的数字）：左下角 (%.4g, %.4g)、' ...
                '右上角 (%.4g, %.4g) -> X [%g, %g]  Y [%g, %g]；' ...
                '折合 X 一格 %.4g px、Y 一格 %.4g px。下一步点"⑥ 分离曲线"。%s'], ...
                x0, y0, x1, y1, cal.xlim, cal.ylim, ...
                cal.gridPx(1), cal.gridPx(2), warnTxt), 'ok');
        [S, mU] = askUnits(S); setS(S); if ~isempty(mU), say(mU,'ok'); end
            return;
        end

        if startsWith(a, '自动')
            say('正在尝试自动读刻度文字…','act');
            d = uiprogressdlg(fig,'Title','自动标定','Indeterminate','on', ...
                              'Message','读取轴刻度文字…');
            cal = [];
            try
                cal = autoCalibFrame(S.I, S.ax);
                try, close(d); catch, end   % 不用 isvalid：它不是基础 MATLAB 函数
            catch ME
                try, close(d); catch, end   % 不用 isvalid：它不是基础 MATLAB 函数
                say(sprintf('自动标定出错：%s', ME.message),'warn');
            end
            if ~isempty(cal)
                a2 = uiconfirm(fig, sprintf(['自动标定结果（方法 %s，置信度 %.2f）：\n\n' ...
                    'X = [%g, %g]\nY = [%g, %g]\n\n若与图上刻度不符，请改用手动标定。'], ...
                    cal.method, cal.confidence, cal.xlim, cal.ylim), '自动标定结果', ...
                    'Options', {'采用','改用手动'}, 'DefaultOption', 1, 'CancelOption', 2);
                if strcmp(a2,'采用')
                    S.cal = cal; setS(S);
                    say(sprintf('标定完成（自动）：X[%g,%g] Y[%g,%g]', cal.xlim, cal.ylim),'ok');
            [S, mU] = askUnits(S); setS(S); if ~isempty(mU), say(mU,'ok'); end
                    return;
                end
            else
                uialert(fig, '自动标定没能得到可靠结果，请改用"只填坐标范围"或"刻度拟合法"。', '提示');
            end
            return;
        end

        % 兜底：任何没被上面分支接住的选择都要有反应，
        % 不能再出现"点了按钮什么都不发生"。
        say(sprintf('未识别的标定方式"%s"，请重新点"④ 标定"选择。', a), 'warn');
        uialert(fig, sprintf(['没有识别你选的方式："%s"。\n\n' ...
            '请重新点"④ 标定"，并在弹窗里选其中一个按钮。'], a), '请重选');
    end

    function txt = sanityNote(perCellVal, axName, jrOne, detail)
        %SANITYNOTE  核对"一格数值"是否合理，只在确实有问题时提示
        %
        %   三条判据（任一命中才提示）：
        %     · 一格像素与"另算的一格像素"差 2 倍以上 —— 典型的把半格当整格
        %     · 一格数值完全不像刻度值（与最近的常见刻度值差 > 10%）
        %     · 图上有两档刻度（jr > 1.5），提示核对填的是哪一档
        %   为什么不设成 4% 这种紧阈值：自动量到的间距本身受碎段影响，
        %   几十像素的偏差就能到 6~7%，紧阈值会天天误报，反而没人看。
        txt = '';
        if ~isfinite(perCellVal) || perCellVal <= 0, return; end
        nice = [0.01 0.02 0.05 0.1 0.2 0.25 0.5 1 2 2.5 5 10 20 25 50 100 200 250 500 1000];
        ratio = nice / perCellVal;
        % 差 2 倍以上（或 1/2 以下）说明量级就错了
        gross = min(abs(log2(ratio)));
        dmin = min(abs(nice - perCellVal) ./ max(nice, perCellVal));
        if gross > 0.9
            txt = sprintf(['\n  · %s 轴：按你填的范围算出的一格 = %.4g，' ...
                '与自动量到的间距差了一倍左右（%s）。\n' ...
                '    请核对：轴框最右/最上那两条线，是不是你填的值所在的位置。\n'], ...
                axName, perCellVal, detail);
        elseif dmin > 0.10
            txt = sprintf(['\n  · %s 轴：一格 = %.4g，不像常见刻度值（%s）。\n' ...
                '    若轴框最右/最上并不是你填的那个位置，请改成那条刻度线的值。\n'], ...
                axName, perCellVal, detail);
        end
        if isfinite(jrOne) && jrOne > 1.5
            txt = [txt sprintf(['  · %s 轴上有两档刻度（最大间距约为平均的 %.1f 倍），' ...
                '请确认填的是轴框最右/最上那条刻度对应的数字。\n'], axName, jrOne)];
        end
    end


    % ================= 标定辅助：自动找原点 + 自动量刻度间距 =================
    function [orgCol, orgRow, spX, spY, jr] = detectOriginAndGrid(I, ax)
        %DETECTORIGINANDGRID  找出 X/Y 轴线的交点（左下角原点）与一大格的像素尺寸。
        %
        %   为什么这么标定最省事：原点给一个锚点，刻度间距给比例，
        %   两者都不需要读图上的数字 —— 数字由用户告知（"一格代表多少"）。
        %   这比"点 2 个刻度 + 猜轴框边界的值"稳得多：轴框四边往往不是
        %   坐标范围（Fig.3B 的轴框比数据范围大 0.04/4.4），把边界当范围
        %   会让整条标定线平移，这正是之前"标定不准确"的根因。
        %
        %   识别顺序（实测 Fig.3A 验证）：
        %     1) 左下角的 y=0 横线：取覆盖率最高的行（多条并列时取最下面那条）
        %     2) y 轴线：最左的长竖线
        %     3) 原点 = 这两条线的交点（左下角那一格十字）
        %     4) 刻度间距：y 轴线上方的短竖刻度 = X；y 轴线右侧的短横刻度 = Y
        %     5) 原点列：左下角那条竖线（x=0 常是虚线，覆盖率只有 0.5~0.95）
        %
        %   ---- 约定：界面统一按【一大格】标定 ----
        %   不再自动判别"大格/半格"（matplotlib 常把次刻度画得与主刻度一样长，
        %   从像素上分不出来，猜错就整条标定差一倍）。这里只给出"所有刻度线的
        %   平均间距"作为参考值，语义固定为"一大格"，并在界面上明确标注出来，
        %   由用户对照图上标注的刻度数字确认或改写。
        D = double(I); lum = 0.299*D(:,:,1)+0.587*D(:,:,2)+0.114*D(:,:,3);
        [H, W] = size(lum);
        ink = lum < 200;
        c0 = max(1,round(ax.colLeft)); c1 = min(W,round(ax.colRight));
        r0 = max(1,round(ax.rowTop));  r1 = min(H,round(ax.rowBottom));
        orgCol = NaN; orgRow = NaN; spX = NaN; spY = NaN;
        jr = [NaN NaN];     % jumpRatio：最大相邻间距/平均间距，用来提示"有更细的刻度"
        if c1-c0 < 10 || r1-r0 < 10, return; end
        spanC = c1-c0+1; spanR = r1-r0+1;

        % ---- (1) y=0 横线 ----
        rowCov = sum(ink(:, c0:c1), 2) / spanC;
        cand = find(rowCov(r0:r1) > 0.75) + r0 - 1;
        if isempty(cand), return; end
        orgRow = max(cand);

        % ---- (2) y 轴线 ----
        colCovAll = sum(ink(r0:r1, :), 1) / spanR;
        longCols = find(colCovAll(c0:c1) > 0.75) + c0 - 1;
        if isempty(longCols), return; end
        axCol = min(longCols);

        % ---- (3) X 的刻度间距 ----
        bandRows = max(1,orgRow-4) : max(1,orgRow-1);
        v = sum(ink(bandRows, :), 1) >= 2;
        v(1:max(1,c0-14)) = false; v(min(numel(v),c1+14):end) = false;
        [spX, rX] = cellSpacing(v);

        % ---- (4) Y 的刻度间距 ----
        bandCols = max(1,axCol+1) : max(1,axCol+4);
        h = sum(ink(:, bandCols), 2) >= 2;
        h(1:max(1,r0-14)) = false; h(min(numel(h),r1+14):end) = false;
        [spY, rY] = cellSpacing(h);
        jr = [rX rY];

        % ---- (5) 原点列 = 左下角那条竖线 ----
        inner = (axCol+3) : (c1-3);
        orgCol = axCol;
        if ~isempty(inner)
            cov = colCovAll(inner);
            hit = find(cov > 0.40);
            if ~isempty(hit)
                cols = inner(hit);
                k = 1;
                while k+1 <= numel(cols) && cols(k+1) == cols(k)+1, k = k+1; end
                orgCol = mean(cols(1:k));
            end
        end
    end

    function [sp, jumpRatio] = cellSpacing(v)
        %CELLSPACING  量出"一大格"的像素间距（只给一个值，语义固定）
        %
        %   为什么只给一个值：自动判别"大格/半格"被验证为不可靠 ——
        %   matplotlib 常把次刻度画得和主刻度一样长，只有标注文字的疏密不同，
        %   像素上分不出"每 0.1 一个未标注刻度"和"每 0.2 一个大格"。
        %   所以界面统一按"一大格"来标定（对话框里会写清楚），
        %   这个值只是参考，用户看着图上的数字确认或改写即可。
        %
        %   量法 =（最右刻度 − 最左刻度）/(刻度数 − 1)：把所有刻度一起平均，
        %   比"取最小间距"稳得多 —— 取最小间距会被"同一刻度被像素切成两段
        %   产生的 3~4 px 假间距"骗到（实测踩过，标定差一倍）。
        %
        %   第二个返回值 jumpRatio =（最大相邻间距）/（平均间距）：
        %   明显 > 1.5 说明图上存在两档刻度，界面会提示用户核对。
        sp = NaN; jumpRatio = NaN;
        cent = tickCenters(v);
        if numel(cent) < 2, return; end
        % 碎段合并：同一刻度被像素切成多段时，段间距只有 3~4 px
        merged = cent(1);
        for k = 2:numel(cent)
            if cent(k) - merged(end) <= 3
                merged(end) = (merged(end)+cent(k))/2;
            else
                merged(end+1) = cent(k); %#ok<AGROW>
            end
        end
        if numel(merged) < 2, return; end
        % 用"出现最多的那个间距"当估计值，而不是平均值：
        % 平均值会被少数碎段/漏检拉偏（实测真值 38 px 被拉成 35.4），
        % 众数对少数异常样本不敏感。
        d = diff(merged);
        d = d(d > 3);
        if isempty(d)
            sp = (merged(end) - merged(1)) / (numel(merged) - 1);
        else
            sp = median(d);
            % 若存在"双倍间距"（说明中间那条刻度漏检了），用较小的一档
            small = d(d < 1.5*sp);
            if ~isempty(small), sp = median(small); end
        end
        if sp > 0, jumpRatio = max(d) / sp; end
    end

    function cent = tickCenters(v)
        %TICKCENTERS  一维布尔序列里"刻度线"的中心位置（只做粗筛，合并在上层）
        v = v(:)';
        e = diff([false, v, false]);
        ss = find(e==1); ee = find(e==-1)-1;
        cent = [];
        for k = 1:numel(ss)
            if ee(k)-ss(k) <= 6
                cent(end+1) = mean(ss(k):ee(k)); %#ok<AGROW>
            end
        end
    end

    function onCurves()
        S = st();
        if ~needImage(S), return; end
        [S, mAl] = alignKnown(S); if ~isempty(mAl), say(mAl,'ok'); end
        setS(S);
        if ~okCal(S.cal)
            uialert(fig,['请先完成"④ 标定"（标定决定像素到数值的换算，' ...
                '没标定就提取不出正确数据）。'],'提示');
            return;
        end
        % ---- 结构法（骨架拓扑）：完全不做颜色区分 ----
        defN = '2';
        if isfield(S,'nExpect') && ~isempty(S.nExpect), defN = num2str(S.nExpect); end
        aN = inputdlg({'期望曲线条数（看图数一下；多了不要紧，少了会丢线）:'}, ...
                      '结构法自动分离', 1, {defN});
        if isempty(aN), say('已取消','warn'); return; end
        nExp = str2double(aN{1});
        if isnan(nExp) || nExp < 1
            uialert(fig,'条数无效','提示'); say('条数无效','err'); return;
        end
        S.nExpect = round(nExp); setS(S);
        say(sprintf('结构法分离（骨架拓扑，不看颜色），期望 %d 条…', S.nExpect),'act');
        d = uiprogressdlg(fig,'Title','分离中','Indeterminate','on', ...
                          'Message','墨迹掩膜 -> 骨架化 -> 剪枝误差棒 -> 拓扑跟踪…');
        try
            fr0 = [S.ax.rowTop S.ax.rowBottom S.ax.colLeft S.ax.colRight];
            rg0 = [min(S.cal.xlim) max(S.cal.xlim) min(S.cal.ylim) max(S.cal.ylim)];
            opt0 = struct(); opt0.extraTracks = loadPrevTracks(S);
            opt0.block = getfielddef(S,'blk',[]);
            % 注意：dropArtifacts 由 refine_curves 消费（不是 trace_skel），这里不传
            Ctmp = trace_skel(S.I, fr0, rg0, S.nExpect, opt0);
            try, close(d); catch, end   % 不用 isvalid：它不是基础 MATLAB 函数
        catch ME
            try, close(d); catch, end   % 不用 isvalid：它不是基础 MATLAB 函数
            stk = '';   % 带上堆栈：否则只看到"位置 2 索引无效"无法定位
            for q = 1:min(4,numel(ME.stack))
                stk = [stk sprintf('\n    at %s (第 %d 行)', ME.stack(q).name, ME.stack(q).line)]; %#ok<AGROW>
            end
            uialert(fig,[ME.message stk],'分离失败');
            say(sprintf('分离失败：%s%s', ME.message, stk),'err'); return;
        end
        cand = struct('seed', {}, 'kind', {}, 'color', {});
        for k = 1:numel(Ctmp)
            jm = round(numel(Ctmp(k).px)/2);
            cand(end+1) = struct('seed', [Ctmp(k).px(jm) Ctmp(k).py(jm)], ...
                                 'kind', 'curve', 'color', Ctmp(k).core); %#ok<AGROW>
        end
        say(sprintf('结构法给出 %d 条候选（不依赖颜色）。', numel(cand)), 'ok');
        if isempty(cand)
            uialert(fig,['自动分色没找到清晰的彩色曲线。\n\n' ...
                '这通常是因为：曲线是同色系（颜色分不开）、或曲线是黑/灰色。\n' ...
                '请点"确定"后在下一步选【手动点选】，在每条曲线上各点一下。'],'提示');
        end
        nCurve = 0;
        if ~isempty(cand) && isfield(cand,'kind')
            nCurve = sum(strcmp({cand.kind},'curve'));
        end
        showImg(S.I, sprintf('候选 %d 条（其中连续曲线 %d 条）', numel(cand), nCurve));
        boxOverlay(S.ax,[0 0.7 0.7]);
        drawCandidates(cand);

        % 选项：全部 / 单条 / 手动点选
        % 注意：没有候选时不要把"全部提取"放进来（它只会白跑一趟），
        % 也不要把 CancelOption 设成 1，否则用户点关闭会被当成"全部提取"。
        % uiconfirm 最多只支持 4 个选项，所以"逐条提取"改成一个入口 + 输入序号，
        % 不能每条曲线一个选项（fig3A 有 7 条会直接报"选项值必须为 1~4 个"）。
        if isempty(cand)
            opts = {'手动点选'};
            msg = '没有可用候选。请选【手动点选】，在预览区逐条点击曲线。';
        else
            opts = {'全部提取', '只提取指定序号…', '手动点选'};
            msg = sprintf(['结构法找到 %d 条候选。\n' ...
                '· 全部提取：一次给出全部 %d 条\n' ...
                '· 只提取指定序号：再输入序号，可多选，如 1 3\n' ...
                '· 手动点选：在预览区逐条点击'], numel(cand), numel(cand));
        end
        a = uiconfirm(fig, msg, '第⑥步 分离曲线', ...
            'Options', opts, 'DefaultOption', 1, 'CancelOption', numel(opts));
        if isempty(a), say('已取消分离'); return; end

        seeds = {};
        if strcmp(a,'全部提取')
            for k=1:numel(cand), seeds{end+1}=cand(k).seed; end %#ok<AGROW>
        elseif startsWith(a,'只提取')
            a2 = inputdlg({'要提取的序号（可多选，如 1 3）:'}, '选择曲线', 1, {'1'});
            if isempty(a2), say('已取消','warn'); return; end
            kk = sscanf(a2{1}, '%d');
            for q = 1:numel(kk)
                if kk(q) >= 1 && kk(q) <= numel(cand), seeds{end+1} = cand(kk(q)).seed; end %#ok<AGROW>
            end
        else
            showImg(S.I,'手动点选：在每条曲线上点一下，点完按右下"完成选择"');
            boxOverlay(S.ax,[0 0.7 0.7]);
            beginPick('seed','请在预览区点击第一条曲线上的点');
            return;
        end
        if isempty(seeds), say('未选择任何曲线','warn'); return; end
        % 存进状态，导出时交给模块4 统一提取
        S.seeds = seeds; setS(S);
        say(sprintf('已选 %d 条。请点"⑦ 预览验证"查看提取效果。', numel(seeds)),'ok');
        runExtract();
    end

    function runExtract()
        S = st();
        [S, mAl] = alignKnown(S); if ~isempty(mAl), say(mAl,'ok'); end
        setS(S);
        if ~isfield(S,'seeds') || isempty(S.seeds)
            uialert(fig,'请先完成"⑥ 自动分离曲线"并选定要提取的系列','提示');
            return;
        end
        % ---- 先问：要不要平滑 ----
        %   默认"保留原曲线细节"（不平滑）。数字化论文图的目的就是还原原图
        %   上的曲线，包括它真实的起伏 —— 平滑会把真实数据抹掉。
        doSmooth = false; spanVal = 0.3;
        if ~isfield(S,'smoothPref')
            a = uiconfirm(fig, sprintf(['提取方式：\n\n' ...
                '· 保留原曲线细节（推荐，默认）：逐列亚像素测量，' ...
                '1:1 对应图像像素列，**不做任何平滑**。\n' ...
                '   原图上的起伏（含真实抖动）原样保留，适合"要原始数据"。\n\n' ...
                '· 轻度平滑：用 LOWESS 局部回归抹掉像素级抖动。' ...
                '图好看，但会改掉真实的高频起伏。\n\n' ...
                '（选一次会记住，之后可在第⑥步重选）']), ...
                '第⑥步 提取方式', ...
                'Options', {'保留原曲线细节（不平滑）','轻度平滑（LOWESS）'}, ...
                'DefaultOption', 1, 'CancelOption', 1);
            doSmooth = startsWith(a, '轻度平滑');
            S.smoothPref = doSmooth; setS(S);
        else
            doSmooth = S.smoothPref;
        end
        if doSmooth
            say('正在提取（LOWESS 平滑 + 交叉验证）…','act');
        else
            say('正在提取（逐列亚像素测量，不平滑）…','act');
        end
        d = uiprogressdlg(fig,'Title','提取中','Indeterminate','on', ...
                          'Message','逐列亚像素取点 + 与数据点交叉验证…');
        try
            % ---- 走骨架内核（与颜色无关）；点选的种子直接作为起点 ----
            seedsPx = [];
            if isnumeric(S.seeds) && ~isempty(S.seeds)
                seedsPx = double(S.seeds(:,1:2));
            elseif iscell(S.seeds)
                for k = 1:numel(S.seeds)
                    if ~isempty(S.seeds{k}), seedsPx(end+1,:) = double(S.seeds{k}(1:2)); end %#ok<AGROW>
                end
            end
            Rk = panel_ref(S.imageFile, S.I);
            fr2 = [S.ax.rowTop S.ax.rowBottom S.ax.colLeft S.ax.colRight];
            rg2 = [min(S.cal.xlim) max(S.cal.xlim) min(S.cal.ylim) max(S.cal.ylim)];
            opt2 = struct();
            opt2.extraTracks = loadPrevTracks(S);
            opt2.block = getfielddef(S,'blk',[]);
            opt2.dropArtifacts = getfielddef(S,'dropArtifacts',false);
            if Rk.found
                % ---- 已知单幅图：与 digitize_final 完全同配方 ----
                % 自动多列播种 + 表里实测的期望条数 + 实测轴框/量程/遮挡框
                % 与批处理使用相同的提取参数。
                nExp2 = Rk.nExpect;
                say(sprintf('按 digitize_final 同配方提取（%s，%d 条）…', Rk.tag, nExp2),'act');
            else
                if isempty(seedsPx)
                    error('没有种子点：请先"自动分离曲线"，或在图上点选每条曲线上的点。');
                end
                nExp2 = max(size(seedsPx,1), round(getfielddef(S,'nExpect',size(seedsPx,1))));
                opt2.seeds = seedsPx;
                opt2.seedsOnly = true;
            end
            % ---- 首选：颜色感知全局 DP 引擎（curve_extract）----
            % 与旧链路(骨架贪心 + DP 精化)相比，它让"颜色"参与分离，并用
            % "最大覆盖"挑路径，fig3A(7 条深浅绿) / fig3D(10 条绿族交叉) 的
            % 浅色曲线不会再被深色线吸走。失败时自动退回旧链路，不影响其它图。
            % 参数必须走 extract_opts（与 run_all 完全同一套），否则界面结果和
            % 批处理结果会对不上。未知图也能用：tag 传空串即取默认参数。
            useColor = false; C2 = [];
            try
               if Rk.found, oc = extract_opts(Rk.tag); else, oc = extract_opts(''); end
               oc.block = getfielddef(S,'blk',[]);
               Cc = curve_extract(S.I, fr2, rg2, nExp2, oc);
               if numel(Cc) == nExp2
                  C2 = Cc; useColor = true;
                  say(sprintf('颜色感知引擎完成：%d 条', numel(C2)), 'ok');
               else
                  say(sprintf('颜色引擎得到 %d 条（期望 %d），改用骨架链路', numel(Cc), nExp2), 'warn');
               end
            catch MEc
               say(sprintf('颜色引擎不可用（%s），改用骨架链路', MEc.message), 'warn');
               C2 = [];
            end
            if ~useColor
               C2 = trace_skel(S.I, fr2, rg2, nExp2, opt2);
            end
            % ---- DP 精化：非交叉硬带 + 二阶全局最优路径 + 本曲线颜色亚像素 ----
            % trace_skel 给的是"身份/引导线"（骨架+混色并集，逐列贪心，会有逐列抖动）；
            % 这里再用全局 DP 把分支选对，最后用混色重心出亚像素 —— 这就是 digitize_final 的做法。
            CR = struct('px',{},'py',{},'span',{});
            if useColor
                for k1 = 1:numel(C2)
                    CR(k1) = struct('px',C2(k1).px(:),'py',C2(k1).py(:),'span',numel(C2(k1).px));
                end
            else
            try
                guides = cell(1,numel(C2)); cores = cell(1,numel(C2));
                for k1 = 1:numel(C2)
                    guides{k1} = [C2(k1).px(:) C2(k1).py(:)];
                    cores{k1}  = C2(k1).core;
                end
                say(sprintf('正在做全局最优精化（DP，%d 条）…', numel(C2)),'act');
                drawnow limitrate;
                tDP = tic;
                CR = refine_curves(S.I, fr2, guides, cores, struct('tag', Rk.tag, ...
                'dropArtifacts', getfielddef(S,'dropArtifacts',false)));
                say(sprintf('DP 精化完成：%d 条，用时 %.1f s', numel(CR), toc(tDP)),'ok');
            catch ME
                say(sprintf('DP 精化失败，已退回骨架结果：%s', ME.message),'warn');
                CR = struct('px',{},'py',{},'span',{});
            end
            end
            useDP = ~isempty(CR) && numel(CR) == numel(C2);
            if ~useDP && ~isempty(C2)
                say('精化结果与引导条数不一致，本次使用骨架结果（数据仍可用）。','warn');
            end
            names = cell(1, numel(C2));
            for k1 = 1:numel(C2), names{k1} = sprintf('Series_%d', k1); end
            R = struct('curves', struct('name',{},'X',{},'Y',{},'color',{},'kind',{},'quality',{}), ...
                       'verdict', 'ok', 'files', {{}});
            for k1 = 1:numel(C2)
                if useDP
                    Xk = (CR(k1).px - fr2(3))*(rg2(2)-rg2(1))/(fr2(4)-fr2(3)) + rg2(1);
                    Yk = rg2(4) - (CR(k1).py - fr2(1))*(rg2(4)-rg2(3))/(fr2(2)-fr2(1));
                else
                    Xk = C2(k1).X; Yk = C2(k1).Y;
                end
                R.curves(k1) = struct('name', names{k1}, 'X', Xk, 'Y', Yk, ...
                    'color', C2(k1).core/255, 'kind', 'curve', 'quality', C2(k1).cover); %#ok<AGROW>
            end
            if getfielddef(S,'dropArtifacts',false) && isfield(CR,'art') && numel(CR)==numel(C2)
                nA = [0 0];
                for k1 = 1:numel(CR)
                    if numel(CR(k1).art) >= 2, nA = nA + CR(k1).art(1:2);
                    else, nA(1) = nA(1) + CR(k1).art(1); end
                end
                nTot = sum(arrayfun(@(c) numel(c.px), CR));
                say(sprintf('已剔除误差棒结构：共 %d 列（%.1f%%）= 大点/短横线 %d + 短竖线 %d；这些列无测量值，由拟合补齐', ...
                    sum(nA), 100*sum(nA)/max(1,nTot), nA(1), nA(2)),'ok');
            end
            if isempty(C2), R.verdict = 'failed'; end
            % ---- 自检：与参考数据逐点比对（一眼看出"和给的数据对不上"）----
            try
                if Rk.found
                    rp2 = fullfile(fileparts(mfilename('fullpath')),'digitized_final',[Rk.tag '.mat']);
                    if exist(rp2,'file')
                        Ref = load(rp2).CR;
                        if numel(Ref) == numel(R.curves)
                            % 与参考在"数据坐标"上比（分辨率无关）：参考的像素先按
                            % 参考图的轴框换成数值，再折算成用户图上的像素当量
                            dm = 0; ncmp = 0;
                            % 与参考在"数据坐标"上比（分辨率无关）。
                            % 关键：不能按第 k 条对第 k 条 —— 两条链路的曲线编号顺序可能不同
                            % （汇聚区排序/合并差异），那样一比就是几十纳米的假偏差。
                            % 改为按"中位 Y 最接近"自动配对。
                            uy = (rg2(4)-rg2(3))/(fr2(2)-fr2(1));
                            XrA = cell(1,numel(Ref)); YrA = cell(1,numel(Ref)); refY = nan(1,numel(Ref));
                            for q = 1:numel(Ref)
                                if isempty(Ref(q).px), continue; end
                                XrA{q} = (Ref(q).px - Rk.frame(3))*(Rk.range(2)-Rk.range(1)) ...
                                         / (Rk.frame(4)-Rk.frame(3)) + Rk.range(1);
                                YrA{q} = Rk.range(4) - (Ref(q).py - Rk.frame(1))*(Rk.range(4)-Rk.range(3)) ...
                                         / (Rk.frame(2)-Rk.frame(1));
                                fq = isfinite(YrA{q});
                                if any(fq), refY(q) = median(YrA{q}(fq)); end
                            end
                            usedRef = false(1,numel(Ref));
                            pairA = []; dAll = []; nbad = 0; xBad = []; medA = []; medB = [];
                            for k2 = 1:numel(R.curves)
                                Xc = R.curves(k2).X; Yc = R.curves(k2).Y;
                                okc = isfinite(Xc) & isfinite(Yc);
                                if ~any(okc), continue; end
                                myY = median(Yc(okc));
                                best = inf; bk = 0;
                                for q = 1:numel(Ref)
                                    if usedRef(q) || ~isfinite(refY(q)), continue; end
                                    if abs(refY(q) - myY) < best, best = abs(refY(q) - myY); bk = q; end
                                end
                                if bk == 0, continue; end
                                usedRef(bk) = true;
                                pairA(end+1) = myY; medA(end+1) = myY;
                                medB(end+1) = median(YrA{bk}(isfinite(YrA{bk})));
                                Xr = XrA{bk}; Yr = YrA{bk};
                                [Xr, ia] = unique(Xr); Yr = Yr(ia);
                                if numel(Xr) < 5, continue; end
                                yi = interp1(Xr, Yr, Xc(okc), 'linear', NaN);
                                d = abs(Yc(okc) - yi);
                                d = d(isfinite(d));
                                if ~isempty(d)
                                   dm = max(dm, max(d) / uy);          % 最大差：只作参考
                                   dAll = [dAll; d(:)]; %#ok<AGROW>
                                   bb = d/uy > 2;                      % >2px 的点：量化"最大差"的来源
                                   if any(bb)
                                       nbad = nbad + sum(bb);
                                       xv = Xc(okc); xv = xv(isfinite(d));
                                       xBad = [xBad; min(xv(bb)); max(xv(bb))]; %#ok<AGROW>
                                   end
                                end
                                ncmp = ncmp + numel(d);
                            end
                            % 诊断：把"界面 vs 参考"的中位 Y 逐对打出来。
                            % 恒定平移会把所有对都推同一个量 —— 一眼就能分辨"整体平移"
                            % 还是"个别曲线不对"。
                            if ~isempty(pairA)
                                p = 1:min(4,numel(pairA));
                                s = '';
                                for q = p
                                    s = [s sprintf('\n      配对%d: 界面中位Y %.2f / 参考 %.2f (差 %+.2f)', ...
                                        q, medA(q), medB(q), medA(q)-medB(q))]; %#ok<AGROW>
                                end
                                say(sprintf('  自检明细（最大差 %0.2f px）:%s', dm, s),'info');
                            end
                            % 判据用中位差：最大差会被个别陡沿/断点/误差棒处的单点拉爆，
                            % 用它当门槛会误报（实测四对里三对差 <0.2 nm，最大差却有 97 px）。
                            if ncmp == 0
                                say('⚠ 自检：没有可比对的点（曲线为空或全 NaN）—— 预览无有效曲线，请检查日志与标定','warn');
                            elseif median(dAll) / max(1e-12, rg2(4)-rg2(3)) < 0.001
                                extra = '';
                                if nbad > 0
                                    extra = sprintf('；>2px 仅 %d 点(%.2f%%)，集中在 X [%.3g, %.3g]', ...
                                        nbad, 100*nbad/numel(dAll), min(xBad), max(xBad));
                                end
                                say(sprintf('自检通过：与参考 %s.mat 一致（中位差 %.3f%% 满量程 = %.2f px，最大 %.2f px%s）', ...
                                    Rk.tag, 100*median(dAll)/(rg2(4)-rg2(3)), median(dAll)/uy, dm, extra),'ok');
                            else
                                say(sprintf('⚠ 自检：中位差 %.3f%% 满量程 (= %.2f px) 偏大，最大 %.2f px —— 轴框或量程可能不匹配', ...
                                    100*median(dAll)/(rg2(4)-rg2(3)), median(dAll)/uy, dm),'warn');
                            end
                        else
                            say(sprintf('⚠ 自检：条数不一致（本机 %d，参考 %d）', numel(R.curves), numel(Ref)),'warn');
                        end
                    end
                end
            catch
            end
            try, close(d); catch, end   % 不用 isvalid：它不是基础 MATLAB 函数
        catch ME
            try, close(d); catch, end   % 不用 isvalid：它不是基础 MATLAB 函数
            uialert(fig, ME.message, '提取失败');
            say(sprintf('提取失败：%s', ME.message),'err'); return;
        end
        S.curves = R.curves; S.verdict = R.verdict;
        S.fitApplied = false;                       % 新提取 -> 复位拟合状态
        try, bFit.Text = '平滑拟合（仅 fig3B/3C）'; catch, end
        setS(S);
        % 上报每条曲线的质量
        for k = 1:numel(R.curves)
            c = R.curves(k);
            if isfinite(c.quality)
                say(sprintf('  %-14s %4d 点，与数据点偏差 %.2f nm  [%s]', ...
                    c.name, numel(c.X), c.quality, c.kind), ...
                    tern(strcmp(c.kind,'suspect'),'warn','info'));
            else
                say(sprintf('  %-14s %4d 点 [%s]', c.name, numel(c.X), c.kind));
            end
        end
        % 雷同检测：多条曲线的结果几乎重合，说明它们在图上本来就分不开
        % （同色系汇聚区、或种子都落到了同一条线上）。这种情况必须明确告诉
        % 用户，否则他会以为"提取到了好几条"，其实是同一条被提取了多遍。
        dup = findDuplicates(R.curves);
        if ~isempty(dup)
            say(sprintf(['⚠ 第 %s 条的结果几乎重合，说明它们在图上是同一条线' ...
                '（常见于同色系曲线在汇聚处）。这些曲线请改用"手动点选"，' ...
                '在彼此分开的那一段上分别点一下。'], mat2str(dup)), 'warn');
        end
        if strcmp(R.verdict,'suspect')
            say(['⚠ 整体判定 suspicious：有曲线与数据点偏差超容差。' ...
                 '建议改用"手动点选"，或把取点方式切到平滑再试。'],'warn');
        else
            say(sprintf('提取完成：%d 条；整体判定 %s', numel(R.curves), R.verdict),'ok');
        end
        % 预览异常不影响已经提取的数据和导出操作。
        try
            onVerify();
        catch ME
            say(sprintf(['曲线已提取到 %d 条（数据可用，可点"导出"）；' ...
                '只是预览绘图出错：%s'], numel(R.curves), ME.message), 'warn');
        end
    end

    function dup = findDuplicates(curves)
        %FINDDUPLICATES  找出"提取结果几乎重合"的曲线编号
        dup = [];
        if numel(curves) < 2, return; end
        for a = 1:numel(curves)
            for b = a+1:numel(curves)
                if isempty(curves(a).X) || isempty(curves(b).X), continue; end
                n = min(numel(curves(a).X), numel(curves(b).X));
                if n < 20, continue; end
                ya = curves(a).Y(round(linspace(1,numel(curves(a).Y),n)));
                yb = curves(b).Y(round(linspace(1,numel(curves(b).Y),n)));
                rng_ = max(1, max(ya)-min(ya));
                if median(abs(ya-yb)) < 0.02*rng_
                    dup(end+1) = a; dup(end+1) = b; %#ok<AGROW>
                end
            end
        end
        dup = unique(dup);
    end

    function finishSeeds()
        S = st();
        if ~strcmp(S.mode,'seed')
            uialert(fig,'当前不在"手动点选"状态。请先点"⑥ 自动分离曲线"并选择"手动点选"。','提示');
            return;
        end
        S.mode='idle'; setS(S);
        bDone.Enable = 'off';
        if isempty(S.picks), say('没有点到任何曲线','warn'); return; end
        seeds = mat2cell(S.picks, ones(size(S.picks,1),1), 2);
        S.seeds = seeds; setS(S);
        runExtract();
    end

    function onToggleArt()
        % 可选预处理：把"带短横线的大点"(填充标记点/误差棒帽)所在列的测量剔除。
        % 判据是水平墨宽 > 2.2x线宽；陡峭曲线段不会被误伤。
        S = st();
        if ~isfield(S,'dropArtifacts') || ~S.dropArtifacts
            S.dropArtifacts = true;  bArt.Text = '剔除大点影响：开（需重新提取）';
            say('已开启：提取时将剔除大点/误差棒帽所在列的测量（这些列交给后续拟合补齐）。请重新执行⑥/⑦。','ok');
        else
            S.dropArtifacts = false; bArt.Text = '剔除大点影响：关';
            say('已关闭：提取恢复为逐列完整测量。','ok');
        end
        setS(S);
    end

    function onFit()
        % 对"经过点拟合的平滑曲线"做稳健平滑拟合（fig3B/3C/3E 适用）
        S = st();
        if isempty(S.curves), uialert(fig,'还没有曲线，请先完成提取','提示'); return; end
        % ---- 双向开关：第一次=拟合，再点一次=撤销恢复原始逐列值 ----
        if isfield(S,'fitApplied') && S.fitApplied
            for k = 1:numel(S.curves)
                if isfield(S.curves(k),'Yraw') && numel(S.curves(k).Yraw) == numel(S.curves(k).Y)
                    S.curves(k).Y = S.curves(k).Yraw;
                end
            end
            S.fitApplied = false; setS(S);
            try, bFit.Text = '平滑拟合（仅 fig3B/3C/3E）'; catch, end
            say('已撤销拟合：恢复为逐列原始测量值。','ok');
            onVerify();
            return;
        end
        % ---- 适用范围：默认只对 fig3B/3C/3E（原曲线是过点拟合的光滑样条）----
        % 其余图是实测/数值曲线，真实起伏有意义 -> 不硬拒绝，但要你明确确认。
        fitTags = {'fig3B','fig3C'};   % fig3E 暂不开放：其拟合仍有未定位的过冲（实测偏 177 px）
        Rk = panel_ref(S.imageFile, S.I);
        if ~Rk.found || ~any(strcmp(Rk.tag, fitTags))
            if Rk.found
                why = sprintf('当前图是 %s，其曲线属于实测/数值结果，真实起伏有意义。', Rk.tag);
            else
                why = '当前图未能识别为已知七张之一，无法确认曲线类型。';
            end
            b2 = uiconfirm(fig, sprintf(['%s\n\n' ...
                '平滑拟合默认只用于 fig3B/3C（原曲线是光滑样条）。\n' ...
                '继续拟合可能抹掉真实起伏；原始值会被保留，再点一次本按键即可恢复。\n\n' ...
                '确定要拟合吗？'], why), '超出默认适用范围', ...
                'Options', {'仍然拟合','取消'}, 'DefaultOption', 2, 'CancelOption', 2);
            if ~strcmp(b2,'仍然拟合'), say('已取消拟合','warn'); return; end
        end
        a = uiconfirm(fig, sprintf(['对 %d 条曲线做稳健平滑拟合？\n\n' ...
            '· 适用：曲线本身是"过数据点拟合出来的光滑样条"（如 fig3B/3C/3E）。\n' ...
            '  原始曲线就是光滑的，拟合比逐列取点更忠实，可同时消掉\n' ...
            '  实心标记点、误差棒帽、竖向长笔画造成的局部突起/毛刺/凹陷。\n' ...
            '  默认**只修这些异常列**，其余列保留原始测量值，不抹掉真实起伏。\n' ...
            '· 不要用于实测型曲线（如 fig2E/fig3D），会抹掉真实起伏。'], numel(S.curves)), ...
            '平滑拟合', 'Options', {'拟合', '取消'}, 'DefaultOption', 1, 'CancelOption', 2);
        if ~strcmp(a,'拟合'), say('已取消拟合'); return; end
        d = uiprogressdlg(fig,'Title','拟合中','Indeterminate','on','Message','稳健拟合 + 异常列局部修复…');
        try
            for k = 1:numel(S.curves)
                if ~isfield(S.curves(k),'Yraw') || numel(S.curves(k).Yraw) ~= numel(S.curves(k).Y)
                    S.curves(k).Yraw = S.curves(k).Y;   % 保留原始逐列值，供撤销
                end
                [Yf, inf1] = fit_smooth(S.curves(k).X, S.curves(k).Yraw, struct());
                S.curves(k).Y = Yf;
                say(sprintf('  %-14s 修复 %d 列（最大修正 %.3g），残差 RMS %.4g，邻域 %d 点', ...
                    S.curves(k).name, inf1.nfix, inf1.maxfix, inf1.rms, inf1.span));
            end
            setS(S);
            try, close(d); catch, end
            S.fitApplied = true; setS(S);
            try, bFit.Text = '撤销拟合（恢复逐列原始值）'; catch, end
            say('拟合完成（再点一次本按键可撤销）。导出用的就是当前坐标。','ok');
            onVerify();
        catch ME
            try, close(d); catch, end
            uialert(fig, ME.message, '拟合失败');
            say(sprintf('拟合失败：%s', ME.message),'err');
        end
    end

    function onVerify()
        S = st();
        if isempty(S.curves), uialert(fig,'还没有曲线','提示'); return; end
        % 标定必须是"真标定"：初标定时 xFromPx/yFromPx 是返回 NaN 的占位句柄，
        % 直接拿来做反算会得到一片 NaN，图上是空的，看着像"没提取到"。
        if isempty(S.cal) || ~okCal(S.cal)
            uialert(fig,'还没有完成标定（第④步），无法把数据坐标反算回像素。','提示');
            return;
        end
        showImg(S.I,'重叠验证：青色细线与原图对照');
        if ~isempty(S.ax), boxOverlay(S.ax,[0 0.7 0.7]); end
        hold(axP,'on');
        cc = lines(numel(S.curves));
        % 把数据坐标反算回像素：标定是线性的，用 xFromPx(0)/xFromPx(1) 得斜率
        pxOf = @(X) (X - S.cal.xFromPx(0)) / (S.cal.xFromPx(1)-S.cal.xFromPx(0));
        pyOf = @(Y) (Y - S.cal.yFromPx(0)) / (S.cal.yFromPx(1)-S.cal.yFromPx(0));
        ndrawn = 0; npts = zeros(1,numel(S.curves)); rng1 = [NaN NaN NaN NaN];
        for k=1:numel(S.curves)
            X = pxOf(S.curves(k).X); Y = pyOf(S.curves(k).Y);
            npts(k) = sum(isfinite(X) & isfinite(Y));
            if k == 1 && numel(X) > 1
               rng1 = [min(X) max(X) min(Y) max(Y)];
            end
            if numel(X) < 2 || npts(k) < 2, continue; end
            ndrawn = ndrawn + 1;
            plot(axP, X, Y, '-', 'Color', [0 0.9 0.95], 'LineWidth', .8, ...
                'Tag','ExtractedOverlay','HitTest','off','PickableParts','none');
        end
        hold(axP,'off');
        axP.XLim=[.5 size(S.I,2)+.5];axP.YLim=[.5 size(S.I,1)+.5];
        chkOverlay.Value=true;drawnow;
        if ndrawn == 0
            say(sprintf(['⚠ 预览：%d 条曲线都没画出来（有效点数 %s；第1条反算像素 X[%.0f %.0f] Y[%.0f %.0f]，图 %dx%d）' ...
                '—— 请查看日志中的标定和像素范围'], numel(S.curves), mat2str(npts), rng1, size(S.I,2), size(S.I,1)), 'warn');
        else
            say(sprintf('预览已更新：画出 %d/%d 条（有效点数 %s）。右侧青色细线为提取结果，可取消“显示提取曲线”对比原图。', ...
                ndrawn, numel(S.curves), mat2str(npts)),'ok');
        end
    end

    function onOverlayToggle()
        visible='off';if chkOverlay.Value && ~chkError.Value,visible='on';end
        set(findobj(axP,'Tag','ExtractedOverlay'),'Visible',visible);
        visible='off';if chkOverlay.Value && chkError.Value,visible='on';end
        set(findobj(axP,'Tag','ErrorOverlay'),'Visible',visible);
        drawnow;
    end

    function onErrorToggle()
        if ~chkError.Value,onOverlayToggle();return;end
        S=st();
        if isempty(S.curves)||~okCal(S.cal)
            chkError.Value=false;uialert(fig,'请先完成标定和曲线提取','显示误差');return;
        end
        if isempty(findobj(axP,'Tag','ExtractedOverlay'))
            onVerify();chkError.Value=true;
        end
        px=cell(1,numel(S.curves));py=px;colors=zeros(numel(px),3);
        for k=1:numel(px)
            px{k}=(S.curves(k).X-S.cal.xFromPx(0))/(S.cal.xFromPx(1)-S.cal.xFromPx(0));
            py{k}=(S.curves(k).Y-S.cal.yFromPx(0))/(S.cal.yFromPx(1)-S.cal.yFromPx(0));
            if isfield(S.curves,'color'),colors(k,:)=255*S.curves(k).color;
            elseif isfield(S.curves,'core'),colors(k,:)=S.curves(k).core;end
        end
        fr=[1 size(S.I,1) 1 size(S.I,2)];
        if ~isempty(S.ax),fr=[S.ax.rowTop S.ax.rowBottom S.ax.colLeft S.ax.colRight];end
        R=panel_ref(S.imageFile,S.I);tag='';block=[];
        if R.found
            tag=R.tag;block=R.block;
            if ~isempty(block)&&~isempty(R.refSize)
                scale=[size(S.I,1)/R.refSize(1) size(S.I,2)/R.refSize(2)];
                block=block.*[scale(1) scale(1) scale(2) scale(2)];
            end
        end
        report=curve_image_error(S.I,px,py,colors,fr,block,tag);
        setappdata(fig,'CurveDigitizerErrors',report);
        delete(findobj(axP,'Tag','ErrorOverlay'));hold(axP,'on');
        for k=1:numel(px)
            e=report.errors{k};rgb=repmat([.5 .5 .5],numel(e),1);
            rgb(isfinite(e)&e<=.5,:)=repmat([0 .7 .15],nnz(isfinite(e)&e<=.5),1);
            rgb(isfinite(e)&e>.5&e<=1.5,:)=repmat([.95 .65 0],nnz(isfinite(e)&e>.5&e<=1.5),1);
            rgb(isfinite(e)&e>1.5,:)=repmat([.95 .1 .1],nnz(isfinite(e)&e>1.5),1);
            scatter(axP,px{k},py{k},5,rgb,'filled','Tag','ErrorOverlay', ...
                'HitTest','off','PickableParts','none');
        end
        hold(axP,'off');chkOverlay.Value=true;onOverlayToggle();
        legendText='绿 ≤0.5 px | 黄 ≤1.5 px | 红 >1.5 px | 灰：遮挡/无可靠笔画';
        if report.nMeasured==0
            lblError.Text=['图像贴线偏差：无可判定点。' newline legendText];
        else
            lblError.Text=sprintf('图像贴线偏差：中位 %.2f px | P95 %.2f px | 最大 %.2f px | 可判定 %d/%d 点\n%s', ...
                report.median,report.p95,report.maximum,report.nMeasured,report.nTotal,legendText);
        end
        say('误差显示已更新：像素偏差按颜色标记，灰色点不计入统计。','ok');
    end

    function onDataPlot()
        S=st();
        if isempty(S.curves),uialert(fig,'请先提取曲线','提示');return;end
        cc=lines(numel(S.curves));
        if ~isempty(S.cal)
            figure('Name','提取结果（数据坐标）','NumberTitle','off');
            hold on; grid on; box on;
            for k=1:numel(S.curves)
                plot(S.curves(k).X, S.curves(k).Y, '-','Color',cc(k,:),'LineWidth',1.3);
            end
            xlim(S.cal.xlim); ylim(S.cal.ylim);
            xlab = 'X'; ylab = 'Y';
            if ~isempty(S.lab)&&isfield(S.lab,'axis')
                xlab = sprintf('%s [%s]', ternStr(S.lab.axis.x.title,'X'), ...
                    ternStr(S.lab.axis.x.unit,''));
                ylab = sprintf('%s [%s]', ternStr(S.lab.axis.y.title,'Y'), ...
                    ternStr(S.lab.axis.y.unit,''));
            end
            xlabel(xlab); ylabel(ylab);
            % 结构体数组的曲线名称转换为 cell 后传给 legend。
            legend({S.curves.name},'Location','best','Interpreter','none');
            tt = '提取结果';
            if isfield(S,'verdict') && strcmp(S.verdict,'suspect')
                tt = '提取结果 —— ⚠ 判定 suspect，部分曲线与数据点偏差超容差';
            end
            title(tt);
        end
    end

    function ok = okCal(cal)
        %OKCAL  标定是否真的可用（不是初标定时的 NaN 占位句柄）
        ok = false;
        if isempty(cal) || ~isstruct(cal), return; end
        if ~isfield(cal,'xFromPx') || ~isfield(cal,'yFromPx'), return; end
        if ~isfield(cal,'xlim') || ~isfield(cal,'ylim'), return; end
        xl = cal.xlim; yl = cal.ylim;
        if numel(xl) ~= 2 || numel(yl) ~= 2, return; end
        if any(~isfinite(xl)) || any(~isfinite(yl)) || diff(sort(xl)) <= 0 || diff(sort(yl)) <= 0
            return;
        end
        try
            x0 = cal.xFromPx(0); y0 = cal.yFromPx(0);
            x1 = cal.xFromPx(1); y1 = cal.yFromPx(1);
        catch
            return;
        end
        ok = isfinite(x0) && isfinite(x1) && isfinite(y0) && isfinite(y1) && ...
             abs(x1-x0) > 0 && abs(y1-y0) > 0;
    end

    function onExport()
        S = st();
        if isempty(S.curves), uialert(fig,'请先完成"⑥ 自动分离曲线"','提示'); return; end
        if ~okCal(S.cal), uialert(fig,'请先完成"④ 标定"','提示'); return; end
        % 名称与单位由用户填写。
        xT='X'; xU=''; yT='Y'; yU='';
        if ~isempty(S.lab) && isfield(S.lab,'axis')   % 标定时已填过名称/单位 -> 默认沿用
            xT = ternStr(S.lab.axis.x.title,'X'); xU = ternStr(S.lab.axis.x.unit,'');
            yT = ternStr(S.lab.axis.y.title,'Y'); yU = ternStr(S.lab.axis.y.unit,'');
        end
        nm = {S.curves.name};
        a = inputdlg([arrayfun(@(k) sprintf('曲线 %d 名称:',k),1:numel(nm), ...
              'UniformOutput',false), {'X 轴名称:','X 轴单位:','Y 轴名称:','Y 轴单位:'}], ...
              '第⑦步：填写名称与单位（导出的表头会用它们）', 1, [nm,{xT,xU,yT,yU}]);
        if isempty(a), say('导出已取消'); return; end
        for k=1:numel(S.curves)
            t = strtrim(a{k});
            if isempty(t), t = sprintf('Series_%d', k); end   % 空名字会让表头非法
            S.curves(k).name = t;
        end
        xT=strtrim(a{numel(nm)+1}); xU=strtrim(a{numel(nm)+2});
        yT=strtrim(a{numel(nm)+3}); yU=strtrim(a{numel(nm)+4});
        setS(S);
        initName = ternStr(S.outPrefix,'digitized');
        [f,p] = uiputfile({'*.csv','CSV 文件'},'选择导出位置（会同时生成多种格式）', initName);
        if isequal(f,0), say('导出已取消'); return; end
        [~,base] = fileparts(f);
        outPrefix = fullfile(p,base);
        lab = struct('axis',struct('x',struct('title',xT,'unit',xU), ...
                                   'y',struct('title',yT,'unit',yU)), ...
                     'legend',struct([]),'units',{{}},'notes',{{}});
        try
            n = writeOutputs(S.curves, lab, outPrefix, S.imageFile, S.cal, S.ax);
        catch ME
            uialert(fig,ME.message,'导出失败');
            say(sprintf('导出失败：%s', ME.message),'err'); return;
        end
        say(sprintf('导出完成：%d 个文件，前缀 %s', n, base),'ok');
        uialert(fig, sprintf('导出完成（%d 个文件）：\n\n%s.csv\n%s.xlsx\n%s.mat\n%s_provenance.txt', ...
            n, outPrefix,outPrefix,outPrefix,outPrefix),'完成','Icon','success');
    end

    function onSelfTest()
        say('--- 环境自检开始 ---','act');
        need = {'m1_readAxes','m2_findCurves','m4_extractCurve', ...
                'curveTools','findAllCurves','colorCurves','scanBySlices', ...
                'scanCurveCandidates','robustLowess','detectMarkers', ...
                'findLegend','extractLineOnly','extractByColumns', ...
                'digitize_curve','annotate_data','extract_pdf_figure'};
        miss = {};
        for k=1:numel(need)
            if isempty(which(need{k})), miss{end+1}=need{k}; end %#ok<AGROW>
        end
        if isempty(miss), say('✔ 全部函数就位','ok');
        else, say(sprintf('✘ 缺少：%s', strjoin(miss,', ')),'err'); end

        d = uiprogressdlg(fig,'Title','自检','Indeterminate','on','Message','算法闭环测试…');
        try
            [ok,me] = quickAlgoTest();
            try, close(d); catch, end   % 不用 isvalid：它不是基础 MATLAB 函数
            if ok, say(sprintf('✔ 追踪算法正常（中位误差 %.2f px）', me),'ok');
            else,  say(sprintf('✘ 算法误差偏大：%.2f px', me),'err'); end
        catch ME
            try, close(d); catch, end   % 不用 isvalid：它不是基础 MATLAB 函数
            say(sprintf('✘ 算法自检异常：%s', ME.message),'err');
        end

        try
            r = ocrBridge(uint8(255*ones(90,240,3)), ...
                          struct('scale',2,'pass2',false,'variants',false));
            if strcmp(r.engine,'none')
                say('△ OCR 引擎不可用（主流程不依赖它，无影响）','warn');
            else
                say(sprintf('✔ OCR 引擎可用（%s，主流程不依赖）', r.engine),'ok');
            end
        catch
            say('△ OCR 检测异常（主流程不依赖，可忽略）','warn');
        end

        [stt,~] = system('python -c "import pymupdf"');
        if stt==0, say('✔ Python + PyMuPDF 可用（支持 PDF 矢量抽取）','ok');
        else, say('△ 未装 PyMuPDF（需要时执行 pip install pymupdf）','warn'); end
        say('--- 自检结束 ---','ok');
    end

    setS(ST);
    say(['就绪。建议顺序：载入单幅图片 → 确认轴框 → ' ...
         '标定（只填图上的坐标范围）→ 分离曲线 → 预览验证 → 导出。']);
end

%
function I = toRGB(I)
%TORGB  统一成三通道 uint8（去掉 alpha / 灰度复制 / 各类型归一化）。
%   不用 im2uint8、不用 ndims：这两个在无工具箱环境下不稳妥。
    n = size(I,3);
    if n == 1
        I = repmat(I,1,1,3);
    elseif n == 2
        I = repmat(I(:,:,1),1,1,3);
    elseif n > 3
        I = I(:,:,1:3);
    end
    if ~isa(I,'uint8')
        if isa(I,'double') || isa(I,'single')
            if isempty(I) || max(I(:)) <= 1
                I = uint8(round(255*min(max(double(I),0),1)));
            else
                I = uint8(round(min(max(double(I),0),255)));
            end
        else
            I = uint8(double(I));
        end
    end
end

function s = ternStr(v,d)
%TERNSTR  取字符串，空则返回默认值
    s = d;
    if ischar(v)
        if ~isempty(strtrim(v)), s = v; end
    elseif isstring(v)
        if strlength(v) > 0, s = char(v); end
    end
end

function s = tern(c,a,b)
%TERN  三目：条件为真取 a，否则取 b（简化嵌套函数里的分支写法）
    if c, s = a; else, s = b; end
end

%
function [ok,medErr] = quickAlgoTest()
%QUICKALGOTEST  合成已知曲线，走"追踪+归约"，比较中心线误差。
%   真值是 round() 后的整数像素，本身含 ±0.5 量化误差，故阈值取 1.2 px。
    H=400; W=800;
    pxc=(100:700)'; pyc=100+150*exp(-(pxc-100)/200);
    I = 255*ones(H,W,3,'uint8');
    for k=-1:1
        r = round(pyc)+k; ok2 = r>=1 & r<=H;
        for ch=1:3
            chI=I(:,:,ch); chI(sub2ind([H W], r(ok2), pxc(ok2)))=0; I(:,:,ch)=chI;
        end
    end
    ax = struct('rowTop',20,'rowBottom',380,'colLeft',80,'colRight',720);
    cal = struct('xFromPx',@(q) q,'yFromPx',@(q) q,'xlim',[80 720],'ylim',[20 380]);
    [res,~] = curveTools('trace', I, ax, cal, [pxc(1), round(pyc(1))], ...
                         struct('colorTol',60,'radius',6));
    calM = struct('mask',res.mask,'xFromPx',@(q) q,'yFromPx',@(q) q);
    [~,~,bi] = curveTools('reduce', res.pathPx, calM, 'fit');
    if isempty(bi.pathReduced), ok=false; medErr=NaN; return; end
    rr = bi.pathReduced;
    refRow = 100+150*exp(-(rr(:,1)-100)/200);
    medErr = median(abs(rr(:,2)-refRow));
    ok = (medErr<1.2) && size(rr,1)>400;
end

%
function n = writeOutputs(curves, lab, outPrefix, srcFile, cal, ax)
%WRITEOUTPUTS  导出 CSV / Excel / MAT / provenance，返回生成文件数
    xT=ternStr(lab.axis.x.title,'X'); xU=ternStr(lab.axis.x.unit,'');
    yT=ternStr(lab.axis.y.title,'Y'); yU=ternStr(lab.axis.y.unit,'');
    if isempty(curves), error('没有可导出的曲线'); end
    % 先剔除空曲线并保证曲线名可用：空曲线会让 min/max 抛异常，
    % 空名字会让 writetable 的表头非法，两者都会让"导出失败"。
    keep = false(1,numel(curves));
    for k=1:numel(curves)
        if numel(curves(k).X) >= 2 && numel(curves(k).X) == numel(curves(k).Y)
            keep(k) = true;
        end
    end
    curves = curves(keep);
    if isempty(curves), error('所有曲线都是空的，无法导出'); end
    for k=1:numel(curves)
        if ~isfield(curves(k),'name') || isempty(strtrim(curves(k).name))
            curves(k).name = sprintf('Series_%d', k);
        end
    end

    multi = numel(curves)>1;
    maxN = max(cellfun(@numel,{curves.X}));
    M = nan(maxN, 2*numel(curves));
    vn = cell(1,2*numel(curves));
    for k=1:numel(curves)
        nx = numel(curves(k).X);
        M(1:nx,2*k-1)=curves(k).X(:);
        M(1:nx,2*k)=curves(k).Y(:);
        if multi
            vn{2*k-1}=matlab.lang.makeValidName(sprintf('%s_X_%s',curves(k).name,xU));
            vn{2*k}=matlab.lang.makeValidName(sprintf('%s_%s',curves(k).name,yU));
        else
            vn{2*k-1}=matlab.lang.makeValidName(sprintf('X_%s',xU));
            vn{2*k}=matlab.lang.makeValidName(sprintf('Y_%s',yU));
        end
    end
    vn = uniqueNames(vn);
    csv = sprintf('%s.csv',outPrefix);
    writetable(array2table(M,'VariableNames',vn), csv);
    n = 1;
    xl = sprintf('%s.xlsx',outPrefix);
    try
        writetable(array2table(M,'VariableNames',vn), xl, 'Sheet','ALL');
        for k=1:numel(curves)
            T = table(curves(k).X(:), curves(k).Y(:), 'VariableNames',{vn{2*k-1},vn{2*k}});
            writetable(T, xl, 'Sheet', matlab.lang.makeValidName(curves(k).name));
        end
        n = n+1;
    catch ME
        warning('writeOutputs:excel', 'Excel 导出失败：%s', ME.message);
    end
    save(sprintf('%s.mat',outPrefix),'curves','lab','cal','ax');
    n = n+1;
    fid = fopen(sprintf('%s_provenance.txt',outPrefix),'w','n','UTF-8');
    fprintf(fid,'===== 数据来源与说明 =====\n');
    fprintf(fid,'源文件      : %s\n', srcFile);
    fprintf(fid,'导出时间    : %s\n', char(datetime('now','Format','yyyy-MM-dd HH:mm:ss')));
    fprintf(fid,'X 轴        : %s  [%s]\n', xT, xU);
    fprintf(fid,'Y 轴        : %s  [%s]\n', yT, yU);
    fprintf(fid,'轴数据范围  : X [%g, %g]   Y [%g, %g]\n', cal.xlim, cal.ylim);
    if ~isempty(ax)
        fprintf(fid,'轴框(像素)  : top=%d bottom=%d left=%d right=%d\n', ...
            round(ax.rowTop),round(ax.rowBottom),round(ax.colLeft),round(ax.colRight));
    end
    fprintf(fid,'\n曲线列表：\n');
    for k=1:numel(curves)
        fprintf(fid,'  %2d. %-26s %6d 点  X[%g, %g]  Y[%g, %g]\n', k, curves(k).name, ...
            numel(curves(k).X), min(curves(k).X), max(curves(k).X), ...
            min(curves(k).Y), max(curves(k).Y));
    end
    fprintf(fid,'\n方法与误差：\n');
    fprintf(fid,'  取点方式：颜色感知全局 DP（混色似然 + 抛物线下包络 + 最大覆盖选路 + 漏检回收）\n');
    fprintf(fid,'  名称单位：用户填写\n');
    fprintf(fid,'  误差说明：受图像分辨率、线宽、遮挡和坐标标定影响；请检查原图叠加与像素偏差\n');
    fprintf(fid,'  引用时请注明"数据由图示数字化得到"\n');
    fclose(fid);
    n = n+1;
end

function vn = uniqueNames(vn)
    seen = containers.Map('KeyType','char','ValueType','double');
    for k=1:numel(vn)
        b = vn{k};
        if isKey(seen,b)
            m = seen(b)+1; seen(b)=m; vn{k}=sprintf('%s_%d',b,m);
        else
            seen(b)=1;
        end
    end
end
    function [S, msg] = askUnits(S)
        % 标定完成后立刻问坐标轴名称与单位：导出的表头、xlsx 变量名、
        % 数据窗图轴标注、provenance 都会用它们。放在标定这一步问，
        % 用户此时正对着图上的轴标签，最不容易填错。
        msg = '';
        if isfield(S,'unitAsked') && S.unitAsked, return; end   % 每条图只问一次
        try
            xT0 = 'X'; xU0 = ''; yT0 = 'Y'; yU0 = '';
            if ~isempty(S.lab) && isfield(S.lab,'axis')
                xT0 = ternStr(S.lab.axis.x.title,'X'); xU0 = ternStr(S.lab.axis.x.unit,'');
                yT0 = ternStr(S.lab.axis.y.title,'Y'); yU0 = ternStr(S.lab.axis.y.unit,'');
            end
            a = inputdlg({'X 轴名称:', 'X 轴单位:', 'Y 轴名称:', 'Y 轴单位:'}, ...
                '第④步 标定：坐标轴名称与单位（导出表头会用）', 1, {xT0, xU0, yT0, yU0});
            if isempty(a), msg = ''; return; end
            S.lab = struct('axis', struct( ...
                'x', struct('title', strtrim(a{1}), 'unit', strtrim(a{2})), ...
                'y', struct('title', strtrim(a{3}), 'unit', strtrim(a{4}))));
            S.unitAsked = true;
            msg = sprintf('坐标轴已记录：X「%s [%s]」 Y「%s [%s]」', ...
                strtrim(a{1}), strtrim(a{2}), strtrim(a{3}), strtrim(a{4}));
        catch ME3
            msg = sprintf('单位输入失败：%s', ME3.message);
        end
    end

    function [S, msg] = alignKnown(S)
        % 当前图片是已知单幅图时，直接用实测轴框+量程+遮挡框，避免界面自动轴框/手填数值与之一致性不足
        msg = '';
        try
            R = panel_ref(S.imageFile, S.I);
            if ~R.found
                if ~isempty(R.err)
                    msg = sprintf('未识别为已知图（%s）：将退回种子链路，结果会与参考数据不同', R.err);
                else
                    msg = sprintf('未识别为已知图（文件名 %s 不在标定表里）：将退回种子链路。请载入 data\\fig3X_conv.png', S.imageFile);
                end
                return;
            end
            fr = R.frame; rg = R.range; blk = R.block;
            S.pxScale = [1 1];   % 载入图/参考图的像素缩放（[y x]）
            S.aspectOK = true;
            % 载入图与标定参考图尺寸不同时，按比例缩放轴框与遮挡框（量程与分辨率无关，不动）
            sfMsg = '';
            if ~isempty(R.refSize)
               Hnow = size(S.I,1); Wnow = size(S.I,2);
               if Hnow ~= R.refSize(1) || Wnow ~= R.refSize(2)
                  sy = Hnow / R.refSize(1); sx = Wnow / R.refSize(2);
                  S.aspectOK = abs(sy - sx) <= 0.002;   % 纯等比？(实测 0.01%~0.02%)
                  fr = [fr(1)*sy, fr(2)*sy, fr(3)*sx, fr(4)*sx];
                  if ~isempty(blk), blk = round(blk .* [sy sy sx sx]); end
                  S.pxScale = [sy sx];
                  if abs(sy - sx) > 0.02*max(sy,sx)
                     sfMsg = [sfMsg, sprintf('；⚠ 长宽比不一致(x%.4f vs y%.4f)：你的图可能被裁剪过，缩放标定不可靠，建议用 data\\%s', sx, sy, R.tag)];
                  end
                  sfMsg = [sfMsg, sprintf('；图尺寸 %dx%d vs 标定参考 %dx%d，轴框已按 x%.4f/x%.4f 缩放', ...
                     Wnow, Hnow, R.refSize(2), R.refSize(1), sx, sy)];
               end
            end
            % ---- 关键：像素轴框优先用"本图实测"，量程仍用标定表 ----
            % 缩放轴框只对"纯等比的同一张图"成立；稍有裁剪/留白差异就会整体偏移
            % （实测 fig3A 平移约 98 px = 50 nm，而曲线形状完全正确）。
            % 物理量程与分辨率无关，所以表里的 range 永远可用。
            S.useFusion = true;
            % 参考像素 -> 本图像素 的仿射映射：由"标定表轴框"与"本图最终轴框"共同决定。
            % 只缩放（pxScale）在轴框有平移时会错位；用两框对齐才是真正的配准。
            refF = R.frame;
            S.mapX = @(px) fr(3) + (px - refF(3)) * (fr(4)-fr(3)) / max(1e-9, refF(4)-refF(3));
            S.mapY = @(py) fr(1) + (py - refF(1)) * (fr(2)-fr(1)) / max(1e-9, refF(2)-refF(1));
            % 本图实测轴框：先测出来并记入日志；但只有"非等比(裁剪过)"才采用它，
            % 因为纯等比图的缩放框源自预设的亚像素轴脊中心，比自动检测更准。
            % 同时把两个数与差值都写进日志 —— 以后再出问题，日志里直接能看到。
            axD = [];
            try
               axD = curveTools('detectaxes', S.I);
            catch ME4
               sfMsg = [sfMsg, sprintf('；本图实测轴框：检测失败（%s）', ME4.message)];
            end
            if ~isempty(axD)
               ref = [axD.rowTop axD.rowBottom axD.colLeft axD.colRight];
               dev = max(abs(ref - fr)) / max(size(S.I));
               sfMsg = [sfMsg, sprintf('；本图实测轴框 %.2f/%.2f/%.2f/%.2f（与缩放框差 %.3f%%）', ...
                  ref, 100*dev)];
               if ~getfielddef(S,'aspectOK',true) && dev > 0.0005
                   fr = ref;
                   % 轴框换了 -> 映射必须跟着换，否则参考轨迹会按旧框落位而错位
                   S.mapX = @(px) fr(3) + (px - refF(3)) * (fr(4)-fr(3)) / max(1e-9, refF(4)-refF(3));
                   S.mapY = @(py) fr(1) + (py - refF(1)) * (fr(2)-fr(1)) / max(1e-9, refF(2)-refF(1));
                   S.useFusion = true;   % 映射已随框更新，融合轨迹仍可用（由墨迹自校验兜底）
                   sfMsg = [sfMsg, '；长宽比不一致（很可能裁剪过）-> 缩放框不可靠，改用本图实测轴框'];
               elseif getfielddef(S,'aspectOK',true) && dev > 0.0005
                   % 纯等比：缩放框源自实测的亚像素轴脊中心，比自动检测更准 -> 保持不动
                   sfMsg = [sfMsg, sprintf('；纯等比图，沿用缩放框（自动框偏 %.1f px，不采用）', dev*max(size(S.I)))];
               end
            end
            S.ax = struct('rowTop',fr(1),'rowBottom',fr(2),'colLeft',fr(3),'colRight',fr(4));
            S.blk = blk;
            cal = struct();
            cal.xFromPx = @(q) rg(1) + (q-fr(3))*(rg(2)-rg(1))/(fr(4)-fr(3));
            cal.yFromPx = @(q) rg(4) - (q-fr(1))*(rg(4)-rg(3))/(fr(2)-fr(1));
            cal.xlim = rg(1:2); cal.ylim = rg(3:4);
            cal.method = 'table'; cal.confidence = 1; cal.nTickX = 0; cal.nTickY = 0; cal.ok = true;
            cal.gridPx = [ (fr(4)-fr(3))/(rg(2)-rg(1)), (fr(2)-fr(1))/(rg(4)-rg(3)) ];
            cal.gridVal = [1 1]; cal.cornerPx = [fr(3) fr(2) fr(4) fr(1)];
            cal.cornerVal = [rg(1) rg(3) rg(2) rg(4)]; cal.originVal = [rg(1) rg(3)];
            cal.cellRule = 'range';
            S.cal = cal;
            msg = sprintf('已按 %s 的实测标定自动对齐（轴框 %.0f/%.0f/%.0f/%.0f）%s', R.tag, fr, sfMsg);
        catch ME2
            msg = sprintf('自动对齐失败（沿用你当前的标定）：%s', ME2.message);
        end
    end

    function v = getfielddef(s, f, d)
        if isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
    end

    function ex = loadPrevTracks(S)
        % 找出与当前图片对应的 tag —— 必须用 panel_ref（按图像内容识别），
        % 否则图片改名/换目录时这里会失配 -> 拿不到混色融合轨迹 -> 结果比 digitize_final 差。
        ex = {};
        if ~getfielddef(S,'useFusion',true), return; end   % 轴框改用本图实测 -> 参考像素轨迹会失配
        try
            R = panel_ref(S.imageFile, S.I);
            tg = R.tag;
            if isempty(tg)
                [~, b0] = fileparts(S.imageFile);
                tg = strrep(b0, '_conv', '');
            end
            fp = fullfile(fileparts(mfilename('fullpath')), 'digitized', [tg '.mat']);
            if exist(fp, 'file')
                Lp = load(fp);
                ks = getfielddef(S, 'pxScale', [1 1]);   % 兜底用的纯缩放
                useMap = isfield(S,'mapX') && isfield(S,'mapY');
                if isfield(Lp, 'curves')
                    for kk = 1:numel(Lp.curves)
                        t = [Lp.curves(kk).px(:), Lp.curves(kk).py(:)];
                        if useMap
                            t(:,1) = S.mapX(t(:,1));      % 两框仿射：含平移，才真正配准
                            t(:,2) = S.mapY(t(:,2));
                        else
                            t(:,1) = t(:,1) * ks(2);
                            t(:,2) = t(:,2) * ks(1);
                        end
                        t(:,1) = round(t(:,1));   % 必须取整：非整数列会在
                        t(:,2) = round(t(:,2));   % trace_skel 里当索引用而报错
                        ex{end+1} = t; %#ok<AGROW>
                    end
                end
                % ---- 自校验（通用防线）：映射到本图后必须真的落在墨上 ----
                % 不依赖任何"分辨率/裁剪/轴框"的簿记判断：坐标系只要错位，
                % 轨迹就会落到空白处，这里直接检测出来并丢弃，绝不让错位数据进入融合。
                try
                    Di = double(S.I);
                    inkv = max(1 - mean(Di,3)/255, (max(Di,[],3)-min(Di,[],3))/255);
                    nh = 0; nb = 0;
                    for kk = 1:numel(ex)
                        t = ex{kk};
                        rr = min(max(round(t(:,2)),1), size(inkv,1));
                        qq = min(max(round(t(:,1)),1), size(inkv,2));
                        v = inkv(sub2ind(size(inkv), rr, qq));
                        nh = nh + numel(v); nb = nb + sum(v > 0.30);
                    end
                    if nh > 0 && nb/nh < 0.5
                        warning('digitizer_app:fusionDropped', ...
                            '参考融合轨迹与本图对不上（仅 %.0f%% 落在墨上），已丢弃，改用骨架内核', 100*nb/nh);
                        ex = {};
                    end
                catch
                end
            end
        catch
            ex = {};
        end
    end
