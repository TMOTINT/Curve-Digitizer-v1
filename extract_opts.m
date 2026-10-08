
function o = extract_opts(tag)
%EXTRACT_OPTS  每张图的提取参数（唯一来源）
%   run_all / selftest / qa_before_after / digitizer_app / t_scale / verify_all
%   必须都用这里，否则"界面跑出来的"和"批处理跑出来的"会对不上。
%
%   lam      DP 的斜率惩罚（二次项系数）。越小越能跟随陡峭/锯齿；太小会让两条路径并线
%   dupFrac  判"两条路径挤在同一根笔画"的阈值
%   wThick   厚度惩罚：圆点/误差棒与曲线同色，只能靠"比线宽更厚"区分
%   inkMax   墨迹灰度上限（fig2E 排除灰色单次记录）
%   snapWin  颜色重吸附半径（px）；0 = 不吸附
%   smooth   光滑先验（snake_smooth）参数；不给 = 不做光滑
%
%   后处理是逐图实测选出来的（t_post_all 的对照结果）：
%     fig2E  snake 让二阶差分 p90 从 5.49 降到 0.15，覆盖率不掉
%     fig3A  snake 覆盖率 0.9999 -> 1.0000，p90 0.95 -> 0.14
%     fig3B/C/D/E 使用颜色证据校正，不启用 smooth。
%     fig3F  真实密集锯齿数据，不能光滑；DP 会为少拐弯而抄近路穿过尖峰，
%            改用大窗口(w=150)的颜色重吸附逐列找本颜色的墨峰
o = struct('lam', 0.02, 'dupFrac', 0.75, 'snapWin', 0, 'wThick', 0.45);
switch tag
   case 'fig2E'
      o.colors = [0 0 0];
      o.inkMax = 0.55;
      o.lam = 0.010;
      o.smooth = struct('win', 12, 'maxShift', 3);
   case 'fig3A'
      o.smooth = struct('win', 10, 'maxShift', 3);
   case {'fig3B','fig3C','fig3E'}
      % Color/width evidence rejects markers and error bars. No smoothing.
      o.dupFrac = 0.50;
      o.wThick = 0;
      o.precisionMode = 'markers';
      blocks=struct('fig3B',[840 1250 1220 2226], ...
                    'fig3C',[840 1265 1310 2339], 'fig3E',[210 600 1150 2165]);
      o.block=blocks.(tag);
   case 'fig3D'
      % Preserve color identity through overlaps. No smoothing.
      o.dupFrac = 0.75;
      o.lam = 0.08;
      o.snapWin = 0;
      o.precisionMode = 'family';
   case 'fig3F'
      o.lam = 0.003;
      o.snapWin = 150;                    % 大窗口重吸附，跟随尖峰
      o.wThick = 0.45;                    % 保留厚度惩罚：抑制贴着坐标轴/边框走
   otherwise
      o.smooth = struct('win', 10, 'maxShift', 3);
end
end