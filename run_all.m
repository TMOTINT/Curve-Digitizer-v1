
function OUT = run_all(varargin)
%RUN_ALL  一键提取全部 7 张图：坐标数据(MAT/CSV/XLSX) + 重合度核对图 + QC 报告
%
%   run_all                       % 全部
%   run_all('figures',{'fig3D'})  % 只跑几张
%   OUT = run_all('csv',false)    % 不导出 CSV/XLSX
%
%   产物：
%     digitized_final/<tag>.mat / .csv / _long.csv / .xlsx
%     qa/<tag>_overlay.png   提取结果叠加在原图上（品红）= 重合度核对图
%     qa/<tag>_unc.png       未被覆盖的墨迹标红
%     qa/<tag>_render.png    提取数据独立重绘
%     qa/linegap_<tag>.png   只标出"曲线笔画"里真正漏检的段
%     qa/QC_report.txt       逐图指标（cover = 曲线笔画重合度，这是主指标）
here = fileparts(mfilename('fullpath')); cd(here);
p = struct('figures',{{}}, 'csv',true, 'xlsx',true, 'outdir','digitized_final', 'qadir','qa');
for k = 1:2:numel(varargin), p.(varargin{k}) = varargin{k+1}; end
if ~exist(p.outdir,'dir'), mkdir(p.outdir); end
if ~exist(p.qadir,'dir'), mkdir(p.qadir); end
S = fig_specs_v2();
if isempty(p.figures), tags = {S.tag}; else, tags = p.figures; end
rep = {}; OUT = struct('tag',{},'curves',{},'qc',{});
fid = fopen(fullfile(p.qadir,'QC_report.txt'),'w','n','UTF-8');
fprintf(fid, '曲线坐标提取 QC 报告  (%s)\n', datestr(now,'yyyy-mm-dd HH:MM:SS'));
fprintf(fid, 'cover  = 曲线笔画被认领的比例（按长度加权）——主指标，越接近 1 越好\n');
fprintf(fid, 'onLine = 路径点落在曲线笔画上的比例\n');
fprintf(fid, 'cen    = 路径偏离笔画中心的中位像素数\n');
fprintf(fid, 'bigGap = 长度 >= 1.5 倍线宽的真实漏检段数\n\n');
fprintf(fid, '%-7s %6s %6s %9s %8s %8s %8s  %s\n','tag','nCurve','expect','cover','onLine','cen(px)','bigGap','曲线颜色');
for i = 1:numel(S)
   if ~any(strcmp(S(i).tag, tags)), continue; end
   tag = S(i).tag; fr = S(i).frame; rg = S(i).range;
   I = imread(fullfile('data', S(i).img)); if size(I,3)==1, I = repmat(I,1,1,3); end
   o = extract_opts(tag);
   t0 = tic; C = curve_extract(I, fr, rg, S(i).nExpect, o); el = toc(t0);
   % MAT（保留旧字段 px/py，界面可直接复用）
   CR = struct('px',{},'py',{},'X',{},'Y',{},'core',{},'cover',{},'span',{});
   for k = 1:numel(C)
      CR(k) = struct('px',C(k).px,'py',C(k).py,'X',C(k).X,'Y',C(k).Y, ...
                     'core',C(k).core,'cover',C(k).evid,'span',numel(C(k).px));
   end
   save(fullfile(p.outdir,[tag '.mat']), 'CR');
   if p.csv
      writeCSV(fullfile(p.outdir,[tag '.csv']), C);
      if p.xlsx
         try, writeXLSX(fullfile(p.outdir,[tag '.xlsx']), C); catch, end
      end
   end
   px = cell(1,numel(C)); py = cell(1,numel(C));
   for k = 1:numel(C), px{k} = C(k).px; py{k} = C(k).py; end
   q = line_metric(I, fr, rg, px, py, tag);
   % 核对图
   O = I; for k = 1:numel(C), O = drawLine(O, C(k).px, C(k).py, [255 0 255]); end
   imwrite(O, fullfile(p.qadir,[tag '_overlay.png']));
   G = uint8(255-(255-double(rgb2gray(I)))*0.45); U = repmat(G,1,1,3);
   U(:,:,1) = max(U(:,:,1), uint8(240*q.gap));
   for c2 = 2:3, Uc=U(:,:,c2); Uc(q.gap)=25; U(:,:,c2)=Uc; end
   imwrite(U, fullfile(p.qadir,['linegap_' tag '.png']));
   try
      R = renderFig(C, rg, S(i));
      print(R, '-dpng', '-r110', fullfile(p.qadir,[tag '_render.png'])); close(R);
   catch, end
   cc = cell(1,numel(C));
   for k = 1:numel(C), cc{k} = sprintf('%d,%d,%d', round(C(k).core)); end
   fprintf('%-7s %6d %6d %9.4f %8.4f %8.2f %8d  %s  (%.1fs)\n', tag, numel(C), S(i).nExpect, ...
      q.cover, q.onLine, q.cen, q.bigGap, strjoin(cc,' | '), el);
   fprintf(fid, '%-7s %6d %6d %9.4f %8.4f %8.2f %8d  %s\n', tag, numel(C), S(i).nExpect, ...
      q.cover, q.onLine, q.cen, q.bigGap, strjoin(cc,' | '));
   OUT(end+1) = struct('tag',tag,'curves',C,'qc',q); %#ok<AGROW>
end
fclose(fid);
% 生成"诚实核对图"：1 px 中心线 + 按偏离墨心着色（绿<=0.5px 黄<=1.5px 红>1.5px）
try, render_check; catch ME, fprintf('render_check 跳过：%s\n', ME.message); end
fprintf('\n产物：%s/ 与 %s/   （QC_report.txt 里的 cover 就是重合度）\n', p.outdir, p.qadir);
end

function R = renderFig(C, rg, sp)
R = figure('Visible','off','Color','w','Position',[100 100 900 620]);
hold on; grid on; box on;
for k = 1:numel(C), plot(C(k).X, C(k).Y, 'LineWidth', 1.1); end
xlim([rg(1) rg(2)]); ylim([rg(3) rg(4)]);
xl = sp.xName; if ~isempty(sp.xUnit), xl = sprintf('%s (%s)', sp.xName, sp.xUnit); end
yl = sp.yName; if ~isempty(sp.yUnit), yl = sprintf('%s (%s)', sp.yName, sp.yUnit); end
xlabel(xl,'Interpreter','none'); ylabel(yl,'Interpreter','none');
title(sprintf('提取结果重绘: %s', sp.tag));
end

function writeCSV(f, C)
n = numel(C); L = zeros(1,n);
for k=1:n, L(k) = numel(C(k).X); end
nmax = max(L); head = {}; M = nan(nmax, 2*n);
for k = 1:n
   M(1:L(k), 2*k-1) = C(k).X(:); M(1:L(k), 2*k) = C(k).Y(:);
   head{end+1} = sprintf('x%d', k); head{end+1} = sprintf('y%d', k); %#ok<AGROW>
end
fid = fopen(f,'w');
fprintf(fid, '%s\n', strjoin(head, ','));
for r = 1:nmax
   fprintf(fid, '%.6f', M(r,1));
   for c2 = 2:2*n, fprintf(fid, ',%.6f', M(r,c2)); end
   fprintf(fid, '\n');
end
fclose(fid);
fid = fopen(strrep(f,'.csv','_long.csv'),'w');
fprintf(fid,'series,x,y\n');
for k = 1:n
   x = C(k).X(:); y = C(k).Y(:);
   for r = 1:numel(x), fprintf(fid,'Series_%d,%.6f,%.6f\n', k, x(r), y(r)); end
end
fclose(fid);
end

function writeXLSX(f, C)
n = numel(C); L = zeros(1,n);
for k=1:n, L(k)=numel(C(k).X); end
nmax = max(L); M = nan(nmax, 2*n); vn = {};
for k = 1:n
   M(1:L(k), 2*k-1) = C(k).X(:); M(1:L(k), 2*k) = C(k).Y(:);
   vn{end+1} = sprintf('x%d',k); vn{end+1} = sprintf('y%d',k); %#ok<AGROW>
end
T = array2table(M, 'VariableNames', matlab.lang.makeValidName(vn));
writetable(T, f);
end

function O = drawLine(O, xs, ys, rgb)
% 按最大位移自适应加密：固定加密会让陡段断成虚线（fig3F 竖直段实测）
H=size(O,1); W=size(O,2); n=numel(xs); if n<2, return; end
xs = xs(:); ys = ys(:); P = zeros(0,2);
for k = 1:n-1
   dx = xs(k+1)-xs(k); dy = ys(k+1)-ys(k);
   m = max(1, ceil(max(abs(dx),abs(dy))));
   t = (0:m-1)'/m;
   P = [P; xs(k)+t*dx, ys(k)+t*dy]; %#ok<AGROW>
end
P = [P; xs(end) ys(end)];
ri = round(P(:,2)); ci = round(P(:,1));
for dr=-1:1, for dc=-1:1
   rr=ri+dr; cc=ci+dc; ok=rr>=1&rr<=H&cc>=1&cc<=W;
   idx=sub2ind([H W], rr(ok), cc(ok));
   O(idx)=rgb(1); O(idx+H*W)=rgb(2); O(idx+2*H*W)=rgb(3);
end, end
end