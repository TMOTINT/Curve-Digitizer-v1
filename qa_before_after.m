
function qa_before_after()
%QA_BEFORE_AFTER  复现"优化前"的旧链路（骨架贪心 + DP 精化）并与新引擎对照
here = fileparts(mfilename('fullpath')); cd(here);
if ~exist(fullfile('qa','before'),'dir'), mkdir(fullfile('qa','before')); end
S = fig_specs_v2();
BLK = struct('fig2E',[1090 1270 860 2080],'fig3B',[840 1250 1220 2226], ...
             'fig3C',[840 1265 1310 2339],'fig3E',[210 600 1150 2165]);
rf = fopen(fullfile('qa','before','BEFORE_AFTER_report.txt'),'w','n','UTF-8');
fprintf(rf, '曲线重合度（只算曲线笔画）—— 优化前 vs 优化后\n');
fprintf(rf, '%-6s | %8s %8s %8s %9s | %8s %8s %8s %9s\n','tag','旧覆盖','旧onInk','旧居中','旧大缺口','新覆盖','新onInk','新居中','新大缺口');
for i = 1:numel(S)
   tag = S(i).tag;
   I = imread(fullfile('data', S(i).img)); if size(I,3)==1, I=repmat(I,1,1,3); end
   fr = S(i).frame; rg = S(i).range; blk = getfielddef(BLK, tag, []);
   o = struct(); o.block = blk;
   try
      C1 = trace_skel(I, fr, rg, S(i).nExpect, o);
      g1 = cell(1,numel(C1)); k1 = cell(1,numel(C1));
      for q = 1:numel(C1), g1{q} = [C1(q).px(:) C1(q).py(:)]; k1{q} = C1(q).core; end
      CR = refine_curves(I, fr, g1, k1, struct('tag', tag));
      q1 = line_metric(I, fr, rg, {CR.px}, {CR.py}, tag);
   catch ME
      fprintf('  %s 旧链路失败：%s\n', tag, ME.message);
      q1 = struct('cover',NaN,'onLine',NaN,'cen',NaN,'bigGap',NaN);
   end
   L = load(fullfile('digitized_final',[tag '.mat'])); CR2 = L.CR;
   q2 = line_metric(I, fr, rg, {CR2.px}, {CR2.py}, tag);
   fprintf(rf, '%-6s | %8.4f %8.4f %8.2f %9d | %8.4f %8.4f %8.2f %9d\n', tag, ...
      q1.cover, q1.onLine, q1.cen, q1.bigGap, q2.cover, q2.onLine, q2.cen, q2.bigGap);
   fprintf('%-6s | %8.4f %8.4f %8.2f %9d | %8.4f %8.4f %8.2f %9d\n', tag, ...
      q1.cover, q1.onLine, q1.cen, q1.bigGap, q2.cover, q2.onLine, q2.cen, q2.bigGap);
end
fclose(rf);
fprintf('报告：qa/before/BEFORE_AFTER_report.txt\n');
end
function v = getfielddef(s,f,d), if isfield(s,f), v=s.(f); else, v=d; end, end
