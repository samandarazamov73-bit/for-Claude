// Слоты ассетов. Положи файл с таким именем в assets/ — игра возьмёт его вместо заглушки.
// Ничего регистрировать не нужно: при загрузке игра сама проверяет, какие файлы есть.
import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';

export const MANIFEST = {
  models: {
    // fit — подогнать размер по длине (z) / высоте (y); rotationY — если модель смотрит не в −Z.
    bus: { file: 'models/bus.glb', label: 'Автобус (кузов + салон)', fit: { length: 12 }, rotationY: 0 },
    wheelchair: { file: 'models/wheelchair.glb', label: 'Электроколяска', fit: { length: 1.05 } },
    hero: { file: 'models/hero.glb', label: 'Главный герой (сидя)', fit: { height: 1.32 }, clips: { wheelchair: 'Sitting', sit: 'Sitting', stand: 'Sitting' } },
    mom: { file: 'models/mom.glb', label: 'Мама', fit: { height: 1.62 }, clips: { stand: 'Idle', walk: 'Walking', sit: 'Sitting' } },
    hospital: { file: 'models/hospital.glb', label: 'Здание больницы' },
  },
  textures: {
    road: { file: 'textures/road', label: 'Асфальт', repeatMeters: 6 },
    sidewalk: { file: 'textures/sidewalk', label: 'Плитка тротуара' },
    grass: { file: 'textures/grass', label: 'Трава' },
    concrete: { file: 'textures/concrete', label: 'Бордюр / бетон' },
    facade0: { file: 'textures/facade0', label: 'Фасад дома 1' },
    facade1: { file: 'textures/facade1', label: 'Фасад дома 2' },
    facade2: { file: 'textures/facade2', label: 'Фасад дома 3' },
    hospitalFacade: { file: 'textures/hospital_facade', label: 'Фасад больницы' },
    busSeat: { file: 'textures/bus_seat', label: 'Ткань сидений' },
    busFloor: { file: 'textures/bus_floor', label: 'Пол автобуса' },
  },
  sounds: {
    engine: { file: 'sounds/engine', label: 'Двигатель (петля)' },
    road: { file: 'sounds/road', label: 'Шум дороги (петля)' },
    interior: { file: 'sounds/interior', label: 'Фон салона (петля)' },
    city: { file: 'sounds/city', label: 'Шум города (петля)' },
    birds: { file: 'sounds/birds', label: 'Птицы у больницы (петля)' },
    motor: { file: 'sounds/wheelchair_motor', label: 'Мотор коляски (петля)' },
    music: { file: 'sounds/music', label: 'Музыка (петля)' },
    door: { file: 'sounds/door', label: 'Двери: шипение' },
    beep: { file: 'sounds/beep', label: 'Писк дверей' },
    bell: { file: 'sounds/bell', label: 'Звонок кнопки' },
    chime: { file: 'sounds/chime', label: 'Гонг автоинформатора' },
    tick: { file: 'sounds/tick', label: 'Поворотник' },
    ramp: { file: 'sounds/ramp', label: 'Пандус' },
  },
};

const TEX_EXT = ['.jpg', '.png', '.webp'];
const SND_EXT = ['.mp3', '.ogg', '.wav'];

// Список файлов папки (python -m http.server и большинство локальных серверов отдают его
// HTML-страницей). Так игра не дёргает несуществующие файлы и в консоли нет ошибок 404.
// null — сервер списков не отдаёт, тогда файлы проверяются запросами по одному.
const listings = new Map();
function listDir(dir) {
  if (!listings.has(dir)) {
    listings.set(dir, (async () => {
      try {
        const res = await fetch(`assets/${dir}/`);
        if (!res.ok || !(res.headers.get('content-type') || '').includes('text/html')) return null;
        const html = await res.text();
        return new Set([...html.matchAll(/href="([^"?#]+)"/g)].map((m) => decodeURIComponent(m[1]).split('/').pop()));
      } catch {
        return null;
      }
    })());
  }
  return listings.get(dir);
}

async function exists(path) {
  const [dir, name] = [path.slice(0, path.lastIndexOf('/')), path.slice(path.lastIndexOf('/') + 1)];
  const list = await listDir(dir);
  return list ? list.has(name) : null;
}

async function firstExisting(base, exts) {
  for (const ext of exts) {
    const known = await exists(base + ext);
    if (known === false) continue;
    try {
      const res = await fetch(`assets/${base}${ext}`);
      if (res.ok) return { url: `assets/${base}${ext}`, res };
    } catch { /* нет файла */ }
  }
  return null;
}

function normalizeModel(gltf, opts) {
  const scene = gltf.scene;
  if (opts.rotationY) scene.rotation.y = opts.rotationY;
  scene.updateMatrixWorld(true);
  const box = new THREE.Box3().setFromObject(scene);
  const size = box.getSize(new THREE.Vector3());
  let scale = opts.scale || 1;
  if (opts.fit?.length && size.z > 0) scale = opts.fit.length / size.z;
  if (opts.fit?.height && size.y > 0) scale = opts.fit.height / size.y;
  scene.scale.multiplyScalar(scale);
  // Ставим на землю и центрируем по X/Z.
  scene.updateMatrixWorld(true);
  const b2 = new THREE.Box3().setFromObject(scene);
  const center = b2.getCenter(new THREE.Vector3());
  scene.position.x -= center.x;
  scene.position.z -= center.z;
  scene.position.y -= b2.min.y;
  return gltf;
}

// Загружает всё, что есть. onItem(label, kind, status) — для экрана загрузки.
export async function loadAssets(onItem = () => {}) {
  const out = { models: {}, textures: {}, sounds: {}, report: [] };
  const loader = new GLTFLoader();
  const tasks = [];
  for (const [key, m] of Object.entries(MANIFEST.models)) {
    tasks.push((async () => {
      try {
        if ((await exists(m.file)) === false) throw new Error('нет файла');
        const gltf = await loader.loadAsync(`assets/${m.file}`);
        out.models[key] = normalizeModel(gltf, m);
        out.report.push({ key, label: m.label, file: m.file, ok: true });
      } catch {
        out.report.push({ key, label: m.label, file: m.file, ok: false });
      }
      onItem(m.label, 'model', !!out.models[key]);
    })());
  }
  const texLoader = new THREE.TextureLoader();
  for (const [key, t] of Object.entries(MANIFEST.textures)) {
    tasks.push((async () => {
      const found = await firstExisting(t.file, TEX_EXT);
      if (found) {
        try {
          const tex = await texLoader.loadAsync(found.url);
          tex.colorSpace = THREE.SRGBColorSpace;
          tex.wrapS = tex.wrapT = THREE.RepeatWrapping;
          tex.anisotropy = 8;
          out.textures[key] = tex;
        } catch { /* битая картинка — заглушка */ }
      }
      out.report.push({ key, label: t.label, file: `${t.file}.jpg/.png`, ok: !!out.textures[key] });
      onItem(t.label, 'texture', !!out.textures[key]);
    })());
  }
  for (const [key, s] of Object.entries(MANIFEST.sounds)) {
    tasks.push((async () => {
      const found = await firstExisting(s.file, SND_EXT);
      if (found) {
        try { out.sounds[key] = await found.res.arrayBuffer(); } catch { /* нет */ }
      }
      out.report.push({ key, label: s.label, file: `${s.file}.mp3/.ogg`, ok: !!out.sounds[key] });
      onItem(s.label, 'sound', !!out.sounds[key]);
    })());
  }
  await Promise.all(tasks);
  return out;
}
