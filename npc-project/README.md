# Minifig NPC Studio

Набор оригинальных NPC в эстетике пластиковых строительных минифигурок для браузерной игры.
Модели строятся процедурно в Three.js, имеют общий скелет, систему анимаций и экспортируются в GLB.

Сейчас готов **NPC 01 — Civilian**. Остальные девять персонажей добавляются по одному на том же стандарте.

## Как открыть

Дважды кликните `npc-project/index.html`. Страница работает с `file://` и офлайн: three.js и JSZip
уже лежат внутри `dist/npc-viewer.js`. Шрифты подгружаются из Google Fonts, без интернета используются системные.

Через локальный сервер тоже можно: `npx serve npc-project`.

## Что умеет просмотрщик

- **Камера:** вращение мышью, зум колесом/щипком, сдвиг правой кнопкой; кнопки «Вид спереди», «Вид сзади», «Вид слева», «Вид справа», «Сброс камеры».
- **Сцена:** сетка, свет вкл/выкл, вращение NPC (турнтейбл и слайдер поворота), пять фонов и свой цвет.
- **Анимации:** 38 клипов с поиском и группами, Play / Pause / Stop / Loop, скорость 0.25x–2x, таймлайн с кадрами, плавный переход между клипами. Пробел — play/pause, ↑/↓ — соседний клип.
- **Лицо:** ручной выбор формы рта (Idle, Open, A, E, O, U, Smile, Frown), бровей и закрытых глаз; поле «Произнести фразу» запускает lip-sync по тексту (кириллица и латиница).
- **Части модели:** любую деталь можно скрыть, чтобы посмотреть устройство.
- **Экспорт:** «Download GLB» (модель, скелет, материал, морфы) и «Download GLB + Animations». Галочка «Склеить меши тела» даёт вариант на 3 draw call.

## Структура

```
npc-project/
  index.html            просмотрщик (открывается двойным кликом)
  css/style.css         интерфейс, светлая и тёмная темы
  js/
    main.js             сцена, камера, свет, плеер анимаций, UI
    skeleton.js         стандарт скелета MiniFig-20 (общий для всех NPC)
    geometry.js         генераторы геометрии (скругления, лямки, C-кисти…)
    parts.js            библиотека деталей: голова, лицо, рот, причёски, торс, руки, ноги, обувь, рюкзак
    materials.js        один PBR-материал + палитра-атлас 32×32
    npc.js              сборка деталей в SkinnedMesh с общим скелетом
    animations.js       38 анимаций: позы, циклы, IK ног, генератор речи; запекание в AnimationClip
    lipsync.js          текст → виземы для Mouth_* морфов
    exporter.js         GLB / GLB + анимации / ZIP всех NPC
    npcs/
      index.js          реестр NPC и план из 10 персонажей
      npc01_civilian.js палитра и набор деталей NPC 01
  models/
    NPC_01_Civilian.glb готовый файл с 38 анимациями
  dist/
    npc-viewer.js       сборка для index.html
    artifact.html       версия страницы, которая грузит библиотеки с CDN
  tools/                сборка, экспорт, валидация, тесты
```

Новый NPC — это новый файл в `js/npcs/` (палитра + список деталей) и строка в `js/npcs/index.js`.
Скелет, масштаб, материалы, анимации и экспорт общие.

## Технические характеристики NPC 01

| Параметр | Значение |
|---|---|
| Рост | 1.65 м (1 единица = 1 метр, +Y вверх, лицо смотрит в +Z) |
| Треугольники / вершины | 11 224 / 7 267 |
| Меши | 14 SkinnedMesh (или 3 в склеенном варианте) |
| Материалы | 1 `MeshPhysicalMaterial` (clearcoat), атлас 32×32 px для цвета и roughness |
| Кости | 20 |
| Морф-таргеты | 11 (4 лицо, 7 рот) |
| GLB | 831 KB с 38 анимациями, 383 KB только модель |
| Проверка | Khronos glTF-Validator: 0 ошибок, 0 предупреждений |

Атрибуты вершин упакованы для игры: индексы костей `UNSIGNED_BYTE`, веса и UV нормализованные целые (всё в рамках glTF 2.0 без расширений).

## Скелет MiniFig-20

```
Root
  Hips
    Spine
      Chest
        Neck
          Head
        LeftShoulder → LeftArm → LeftForearm → LeftHand
        RightShoulder → RightArm → RightForearm → RightHand
    LeftUpperLeg → LeftLowerLeg → LeftFoot
    RightUpperLeg → RightLowerLeg → RightFoot
```

У всех костей в позе покоя нулевой поворот, оси совпадают с осями модели (+X — левая сторона персонажа).
Торс жёсткий, как у пластиковой фигурки: `Spine` наклоняет его в поясе, `Chest` даёт поворот и дыхание.
Колени и локти скрыты внутри формы и не видны в покое, но позволяют сгибать руки и ноги.

## Меши и морф-таргеты

`Head_Mesh`, `Hair_Mesh`, `Face_Mesh`, `Mouth_Mesh`, `Torso_Mesh`, `LeftArm_Mesh`, `RightArm_Mesh`,
`LeftHand_Mesh`, `RightHand_Mesh`, `Hips_Mesh`, `LeftLeg_Mesh`, `RightLeg_Mesh`, `Shoes_Mesh`, `Backpack_Mesh`.

- `Face_Mesh`: `Blink`, `Brows_Angry`, `Brows_Raised`, `Brows_Sad`
- `Mouth_Mesh`: `Mouth_Open`, `Mouth_A`, `Mouth_E`, `Mouth_O`, `Mouth_U`, `Mouth_Smile`, `Mouth_Frown`
- `Mouth_Idle` — все веса рта равны 0.

## Анимации

| Клип | Группа | Сек | Режим |
|---|---|---|---|
| Idle | Idle | 3.00 | loop |
| Idle_Breathing | Idle | 4.00 | loop |
| Idle_Combat | Combat | 1.20 | loop |
| Walk | Locomotion | 1.00 | loop |
| Walk_Slow | Locomotion | 1.40 | loop |
| Walk_Fast | Locomotion | 0.76 | loop |
| Walk_Backward | Locomotion | 1.10 | loop |
| Run | Locomotion | 0.62 | loop |
| Sprint | Locomotion | 0.46 | loop |
| Turn_Left | Locomotion | 1.00 | one-shot |
| Turn_Right | Locomotion | 1.00 | one-shot |
| Jump | Locomotion | 1.25 | one-shot |
| Land | Locomotion | 0.75 | one-shot |
| Fall | Locomotion | 0.90 | loop |
| Get_Up | Locomotion | 2.10 | one-shot |
| Punch_Right | Combat | 0.62 | one-shot |
| Punch_Left | Combat | 0.50 | one-shot |
| Punch_Combo | Combat | 1.50 | one-shot |
| Kick | Combat | 1.00 | one-shot |
| Block | Combat | 1.00 | loop |
| Dodge | Combat | 0.80 | one-shot |
| Hit_Reaction | Combat | 0.70 | one-shot |
| Death | Combat | 1.90 | one-shot |
| Wave | Social | 1.60 | loop |
| Point | Social | 1.50 | one-shot |
| Clap | Social | 0.90 | loop |
| Look_Around | Social | 4.00 | loop |
| Shake_Head | Social | 1.30 | one-shot |
| Nod | Social | 1.10 | one-shot |
| Talk | Talk | 3.20 | loop |
| Talk_Excited | Talk | 2.40 | loop |
| Talk_Angry | Talk | 2.40 | loop |
| Talk_Calm | Talk | 4.00 | loop |
| Celebrate | Emotes | 1.20 | loop |
| Shrug | Emotes | 1.30 | one-shot |
| Think | Emotes | 3.00 | loop |
| Sit_Idle | Emotes | 3.00 | loop |
| Dance | Emotes | 1.00 | loop |

Анимации работают на месте (in place). Исключение — `Turn_Left` / `Turn_Right`: они поворачивают кость `Root` на 90°, это можно использовать как root motion.
Ходьба и бег держат подошвы на полу; ноги в приседаниях, стойках и прыжках решаются через IK.
В клипах нет треков для костей, которые остаются в позе покоя: three.js, Unity и Unreal в этом случае используют bind pose.
Talk-клипы двигают рот через морфы, так что lip-sync из звука можно подключить к тем же `Mouth_*`.

## Использование в игре (three.js)

```js
import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { clone } from 'three/addons/utils/SkeletonUtils.js';

const gltf = await new GLTFLoader().loadAsync('models/NPC_01_Civilian.glb');
const npc = clone(gltf.scene);          // для нескольких NPC клонируйте через SkeletonUtils
scene.add(npc);

const mixer = new THREE.AnimationMixer(npc);
const clip = (name) => THREE.AnimationClip.findByName(gltf.animations, name);
mixer.clipAction(clip('Walk')).play();
// в цикле: mixer.update(dt)

// ручное управление ртом / lip-sync
const mouth = npc.getObjectByName('Mouth_Mesh');
mouth.morphTargetInfluences[mouth.morphTargetDictionary.Mouth_A] = 1;
```

Для Unity подходит glTFast или UnityGLTF, для Unreal — встроенный импорт glTF (Interchange).

## Разработка

```
npm install
npm run build        # dist/npc-viewer.js и dist/artifact.html
npm run export-glb   # models/*.glb через headless Chromium
npm run validate     # Khronos glTF-Validator
npm run smoke        # прогон интерфейса, экспорт и скриншоты в test-output/
```

Дизайн персонажей оригинальный: без логотипов, фирменных принтов и копий существующих наборов.
