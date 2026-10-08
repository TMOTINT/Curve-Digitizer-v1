
function selftest()
% 在另一台电脑上先跑这个：确认依赖齐全、程序能独立工作
fprintf('=== 依赖检查 ===\n');
need = {'bwdist','bwmorph','imfindcircles','regionprops','imresize','strel','bwareaopen','imclose','imopen','graythresh','prctile','imfinfo','imerode'};
bad = {};
for k = 1:numel(need)
   okk = exist(need{k}, 'file') > 0;
   fprintf('  %-16s %s\n', need{k}, tern(okk,'OK','缺失'));
   if ~okk, bad{end+1} = need{k}; end %#ok<AGROW>
end
if ~isempty(bad)
   fprintf('  X 缺少: %s\n    需要 Image Processing Toolbox；prctile 需 MATLAB R2023b+ 或 Statistics Toolbox\n', strjoin(bad,', '));
   return;
end
fprintf('\n=== 标定表 ===\n');
S = fig_specs_v2(); fprintf('  标定表: %d 张\n', numel(S));

fprintf('\n=== 颜色感知引擎（curve_extract）逐图自检 ===\n');
BLK = struct('fig2E',[1090 1270 860 2080],'fig3B',[840 1250 1220 2226], ...
             'fig3C',[840 1265 1310 2339],'fig3E',[210 600 1150 2165]);
allok = true;
for i = 1:numel(S)
   tag = S(i).tag;
   I = imread(fullfile('data', S(i).img)); if size(I,3)==1, I = repmat(I,1,1,3); end
   o = extract_opts(tag); o.block = getfielddef(BLK, tag, []);
   t0 = tic; C = curve_extract(I, S(i).frame, S(i).range, S(i).nExpect, o); el = toc(t0);
   okn = numel(C) == S(i).nExpect;
   allok = allok && okn;
   fprintf('  %-6s %d/%d 条  %5.1fs  %s\n', tag, numel(C), S(i).nExpect, el, tern(okn,'OK','条数不符'));
end

fprintf('\n=== 已知图识别（panel_ref）===\n');
for tag = {'fig2E','fig3B'}
   i = find(strcmp({S.tag}, tag{1}));
   I = imread(fullfile('data', S(i).img)); if size(I,3)==1, I = repmat(I,1,1,3); end
   R = panel_ref(S(i).img, I);
   fprintf('  %-6s found=%d tag=%s nExpect=%d\n', tag{1}, R.found, R.tag, R.nExpect);
end

if allok
   fprintf('\n自检完成：全部通过，可以正常运行 digitizer_app / run_all。\n');
else
   fprintf('\n自检完成：有条数不符，请查看上面的输出。\n');
end
end
function s = tern(c,a,b), if c, s=a; else, s=b; end, end
function v = getfielddef(s,f,d), if isfield(s,f), v=s.(f); else, v=d; end, end