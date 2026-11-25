#!/bin/bash
# Скелет и анимации для людей автора (Meshy, A-поза, без рига) → the_last_shake/sanatorium/models/story_*.glb
#   bash rig_people.sh <папка с исходными story_*.glb> <python, в котором есть bpy (Blender как модуль)>
# Образец (чьи кости и анимации): psycho — мужчины, mom — женщины, grandpa — старики. Рост — в метрах.
# Последний столбец — в какой руке сумка (висит отвесно), если есть.
SRC=$1; BPY=$2
HERE=$(cd "$(dirname "$0")" && pwd)
GAME=$HERE/../../../the_last_shake
while read n ref h anims bag; do
  python3 -I $HERE/build_rig.py $SRC/$n.glb $GAME/characters/$ref.glb $GAME/sanatorium/models/$n.glb $h $BPY $anims $bag
done <<'TABLE'
story_doctor psycho 1.76 idle_loop,walk_loop,talk_loop,run_loop
story_patient grandpa 1.66 idle_loop,walk_loop,talk_loop
story_people_sit_1 mom 1.58 idle_loop,walk_loop,talk_loop,stand_ref
story_people_sit_2 psycho 1.74 idle_loop,walk_loop,talk_loop
story_people_sit_3 mom 1.66 idle_loop,walk_loop,talk_loop,stand_ref Right
story_people_sit_4 grandpa 1.68 idle_loop,walk_loop,talk_loop
story_people_sit_5 psycho 1.75 idle_loop,walk_loop,talk_loop
story_people_sit_6 mom 1.62 idle_loop,walk_loop,talk_loop,stand_ref Right
story_pharmacist mom 1.63 idle_loop,walk_loop,talk_loop,stand_ref
story_shukhrat psycho 1.76 idle_loop,walk_loop,talk_loop,run_loop
story_son psycho 1.72 idle_loop,walk_loop,talk_loop,run_loop
TABLE
