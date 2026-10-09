
function t_scale()
%T_SCALE  使用示例图的不同缩放比例检查提取结果。
here = fileparts(mfilename('fullpath')); cd(here);
S = fig_specs_v2();
BLK = struct('fig2E',[1090 1270 860 2080],'fig3B',[840 1250 1220 2226], ...
             'fig3C',[840 1265 1310 2339],'fig3E',[210 600 1150 2165]);
scales = [1.0 0.93 0.80 0.62];
for i = 1:numel(S)
   tag = S(i).tag;
   I0 = imread(fullfile('data', S(i).img)); if size(I0,3)==1, I0=repmat(I0,1,1,3); end
   fprintf('%-6s expect=%d :', tag, S(i).nExpect);
   for sc = scales
      I = imresize(I0, sc);
      fr = S(i).frame .* [sc sc sc sc];
      b = getfielddef(BLK, tag, []);
      if isempty(b), bs = []; else, bs = b .* [sc sc sc sc]; end
      o = extract_opts(tag); o.block = bs;
      C = curve_extract(I, fr, S(i).range, S(i).nExpect, o);
      fprintf('  %.2fx->%d', sc, numel(C));
   end
   fprintf('\n');
end
end
function v = getfielddef(s,f,d), if isfield(s,f), v=s.(f); else, v=d; end, end