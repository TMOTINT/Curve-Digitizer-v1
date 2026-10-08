
function t_edge()
%T_EDGE  边界情形与隐藏 bug 专项测试
here = fileparts(mfilename('fullpath')); cd(here);
S = fig_specs_v2(); iA = find(strcmp({S.tag},'fig3A'));
I = imread(fullfile('data', S(iA).img)); if size(I,3)==1, I=repmat(I,1,1,3); end
ok = @(c,m) fprintf('  [%s] %s\n', tern(c,'OK','!!'), m);

fprintf('--- 已知图识别 ---\n');
R = panel_ref(S(iA).img, I);
ok(R.found && strcmp(R.tag,'fig3A'), sprintf('panel_ref 已知图: found=%d tag=%s nExpect=%d', R.found, R.tag, R.nExpect));
R2 = panel_ref('', uint8(rand(300,400,3)*255));
ok(~R2.found, sprintf('panel_ref 未知图: found=%d (应 0)', R2.found));

fprintf('--- 指标函数退化输入 ---\n');
q = line_metric(I, S(iA).frame, S(iA).range, {}, {}, 'fig3A');
ok(isfinite(q.cover) && q.cover==0, sprintf('空曲线: cover=%.3f (应为 0 且非 NaN)', q.cover));
q2 = line_metric(I, S(iA).frame, S(iA).range, {[500;501]}, {[300;301]}, 'fig3A');
ok(isfinite(q2.cover), sprintf('两个点: cover=%.4f', q2.cover));

fprintf('--- 掩膜函数空白图 ---\n');
[ink,wl] = ink_for_figure(uint8(255*ones(400,500,3)), [10 390 10 490], 'fig3A');
ok(sum(ink(:))==0 && isfinite(wl), sprintf('全白图: ink=%d px wLine=%.1f', sum(ink(:)), wl));

fprintf('--- 引擎退化输入 ---\n');
C = curve_extract(uint8(255*ones(400,500,3)), [10 390 10 490], [0 1 0 1], 3, struct());
ok(isempty(C), sprintf('全白图提取: %d 条 (应 0)', numel(C)));
C0 = curve_extract(I, S(iA).frame, S(iA).range, 0, struct());
ok(isempty(C0), sprintf('nExpect=0: %d 条 (应 0)', numel(C0)));

fprintf('--- 不同分辨率的图（界面常见：图片/ 里的原图比 data/ 大）---\n');
Ih = imresize(I, 0.62);
sc = size(Ih,1)/size(I,1);
frS = round(S(iA).frame .* [sc sc sc sc]);
o = struct('lam',0.02, 'block', round([700 1000 1500 2300] .* [sc sc sc sc]));
Cs = curve_extract(Ih, frS, S(iA).range, S(iA).nExpect, o);
ok(numel(Cs)==S(iA).nExpect, sprintf('0.62x 缩放图: %d/%d 条', numel(Cs), S(iA).nExpect));

fprintf('--- digitized/ 旧轨迹回读（界面 loadPrevTracks 用）---\n');
Lp = load(fullfile('digitized','fig3A.mat'));
ok(isfield(Lp,'curves') && isfield(Lp.curves,'px') && isfield(Lp.curves,'py'), ...
   sprintf('digitized/fig3A.mat: %d 条, 字段 %s', numel(Lp.curves), strjoin(fieldnames(Lp.curves)',',')));

fprintf('--- 导出文件回读 ---\n');
T = readtable(fullfile('digitized_final','fig3A.xlsx'));
ok(height(T)>100, sprintf('xlsx 回读: %dx%d', height(T), width(T)));
Cc = readcell(fullfile('digitized_final','fig3A.csv'));
ok(size(Cc,2)==2*S(iA).nExpect, sprintf('csv 列数 %d (应 %d = 2*%d 条曲线)', size(Cc,2), 2*S(iA).nExpect, S(iA).nExpect));
M = load(fullfile('digitized_final','fig3A.mat'));
ok(numel(M.CR)==S(iA).nExpect && all(isfinite(M.CR(1).X)), 'mat CR 结构与数值 OK');

fprintf('--- 标定表转发 ---\n');
S1 = fig_specs(); S2 = fig_specs_v2();
ok(numel(S1)==numel(S2), sprintf('fig_specs 转发: %d 张', numel(S1)));
end
function s = tern(c,a,b), if c, s=a; else, s=b; end, end
