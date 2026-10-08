
function verify_all()
%VERIFY_ALL  一键跑完全部验证，报告写入 qa/VERIFY_report.txt
%   1) selftest       环境依赖 + 7 张图逐张试跑 + 已知图识别
%   2) run_all        重新提取全部图（并写 QC_report.txt）
%   3) qa_line        曲线笔画重合度 + 漏检诊断图
%   4) audit_curves   逐条曲线的失真体检（抖动 / 被大点吸附 / 出墨 / 撞车）
%   5) check_calib    用 x=0、y=0 虚线参考线独立校验坐标标定
%   6) t_edge         边界与隐藏 bug（空曲线 / 全白图 / nExpect=0 / 导出回读）
%   7) t_scale        不同分辨率下的鲁棒性
here = fileparts(mfilename('fullpath')); cd(here);
if ~exist('qa','dir'), mkdir('qa'); end
rf = fullfile('qa','VERIFY_report.txt');
diary(rf);
fprintf('===== 曲线提取器 全量验证 =====\n');
try
   fprintf('\n----- 1/7 selftest -----\n');      selftest;
catch ME, fprintf('selftest 失败: %s\n', ME.message); end
try
   fprintf('\n----- 2/7 run_all -----\n');       run_all;
catch ME, fprintf('run_all 失败: %s\n', ME.message); end
try
   fprintf('\n----- 3/7 qa_line -----\n');       qa_line;
catch ME, fprintf('qa_line 失败: %s\n', ME.message); end
try
   fprintf('\n----- 4/7 audit_curves -----\n');  audit_curves;
catch ME, fprintf('audit 失败: %s\n', ME.message); end
try
   fprintf('\n----- 5/7 check_calib -----\n');   check_calib;
catch ME, fprintf('check_calib 失败: %s\n', ME.message); end
try
   fprintf('\n----- 6/7 t_edge -----\n');        t_edge;
catch ME, fprintf('t_edge 失败: %s\n', ME.message); end
try
   fprintf('\n----- 7/7 t_scale -----\n');       t_scale;
catch ME, fprintf('t_scale 失败: %s\n', ME.message); end
fprintf('\n===== 验证结束 =====\n');
diary off;
fprintf('验证报告：%s\n', rf);
end
