
function qa_line()
%QA_LINE  只用"曲线笔画"口径复核 7 张图的重合度，并输出漏检诊断图 qa/linegap_<tag>.png
%   cover  = 长度加权的"曲线笔画被认领"比例（这才是"像不像原图"的指标）
%   bigGap = 长度 >= 1.5*线宽 的漏检笔画段数（真正的缺口）
here = fileparts(mfilename('fullpath')); cd(here);
S = fig_specs_v2();
fprintf('%-6s %4s %10s %9s %8s %8s %8s %8s\n','tag','n','cover','onLine','cen(px)','笔画数','线宽px','大缺口');
for i = 1:numel(S)
   tag = S(i).tag;
   I = imread(fullfile('data', S(i).img)); if size(I,3)==1, I=repmat(I,1,1,3); end
   L = load(fullfile('digitized_final',[tag '.mat'])); CR = L.CR;
   q = line_metric(I, S(i).frame, S(i).range, {CR.px}, {CR.py}, tag);
   fprintf('%-6s %4d %10.4f %9.4f %8.2f %8d %8.1f %8d\n', tag, numel(CR), ...
      q.cover, q.onLine, q.cen, q.nRun, q.wLine, q.bigGap);
   if ~exist('qa','dir'), mkdir('qa'); end
   G = uint8(255-(255-double(rgb2gray(I)))*0.40); U = repmat(G,1,1,3);
   U(:,:,1) = max(U(:,:,1), uint8(240*q.gap));
   for c2 = 2:3, Uc=U(:,:,c2); Uc(q.gap)=20; U(:,:,c2)=Uc; end
   imwrite(U, fullfile('qa',['linegap_' tag '.png']));
end
end
