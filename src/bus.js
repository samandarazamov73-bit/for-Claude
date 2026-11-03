// Автобус-заглушка: кузов, салон, двери, откидной пандус, табло, кнопка вызова.
// Координаты автобуса: начало — на земле в центре, «перед» — −Z, правый борт (двери) — +X.
// Если в assets есть bus.glb, он заменяет кузов и салон (см. assets.js / ASSETS.md).
import * as THREE from 'three';
import { CONFIG } from './config.js';
import { STORY } from './story.js';
import { Batcher, boxUV, matrix } from './geom.js';
import * as TX from './textures.js';
import { Human } from './characters.js';
import { rng } from './utils.js';

const B = CONFIG.bus;
const HW = B.width / 2;      // 1.275
const FY = B.floorY;         // пол салона
const L2 = B.length / 2;     // 6
const WIN_Y0 = 1.2, WIN_Y1 = 2.5, ROOF_Y = B.height;

export const DOORS = {
  front: { z0: -5.65, z1: -4.35 },
  middle: { z0: -0.25, z1: 1.25 },
};

export class Bus {
  constructor(assets = {}) {
    this.root = new THREE.Group();
    this.root.name = 'bus';
    this.body = new THREE.Group();     // кузов качается на подвеске, колёса — нет
    this.root.add(this.body);
    this.wheels = [];
    this.doorOpen = { front: 0, middle: 0 };
    this.rampOut = 0;                  // 0 — сложен на полу, 1 — откинут на тротуар
    this.indicator = 0;                // поворотник: 0 нет, 1 правый, -1 левый
    this.stopRequested = false;
    this.interactables = [];
    this.r = rng(7);

    const M = this.m = {
      paint: new THREE.MeshStandardMaterial({ color: 0xf4f5f3, roughness: 0.45, metalness: 0.1 }),
      stripe: new THREE.MeshStandardMaterial({ color: 0x1d5fa8, roughness: 0.45 }),
      dark: new THREE.MeshStandardMaterial({ color: 0x2b2f33, roughness: 0.6 }),
      inner: new THREE.MeshStandardMaterial({ color: 0xd9dcdf, roughness: 0.8 }),
      ceiling: new THREE.MeshStandardMaterial({ color: 0xeef0f2, roughness: 0.9 }),
      floor: new THREE.MeshStandardMaterial({ map: assets.busFloor || TX.busFloor(), roughness: 0.95 }),
      seat: new THREE.MeshStandardMaterial({ map: assets.busSeat || TX.busSeat(), roughness: 0.95 }),
      shell: new THREE.MeshStandardMaterial({ color: 0x8d949b, roughness: 0.6 }),
      pole: new THREE.MeshStandardMaterial({ color: 0xf2c230, roughness: 0.35, metalness: 0.3 }),
      glass: new THREE.MeshStandardMaterial({ color: 0x2b4150, roughness: 0.05, metalness: 0.2, transparent: true, opacity: 0.28, side: THREE.DoubleSide, depthWrite: false }),
      tire: new THREE.MeshStandardMaterial({ color: 0x141414, roughness: 0.9 }),
      rim: new THREE.MeshStandardMaterial({ color: 0xa7adb3, roughness: 0.4, metalness: 0.6 }),
      lightStrip: new THREE.MeshStandardMaterial({ color: 0xffffff, emissive: 0xfff4e0, emissiveIntensity: 1.6 }),
      blue: new THREE.MeshStandardMaterial({ color: 0x1d5fa8, roughness: 0.6 }),
      ramp: new THREE.MeshStandardMaterial({ color: 0x55595d, roughness: 0.9 }),
      indicatorOff: new THREE.MeshStandardMaterial({ color: 0x6b4a10, emissive: 0xffa000, emissiveIntensity: 0 }),
    };

    this.placeholder = new THREE.Group();
    this.placeholder.name = 'bus-placeholder';
    this.body.add(this.placeholder);
    this.buildShell();
    this.buildInterior();
    this.buildDoors();
    this.buildRamp();
    this.buildBoards();
    this.buildWheels();
    this.buildPeople();

    // Точки салона (в координатах кузова). Их можно задать пустышками в bus.glb.
    this.anchors = {
      wheelchair: { pos: new THREE.Vector3(-0.78, FY, 0.72), yaw: Math.PI },   // лицом назад, спиной к упору
      mom: { pos: new THREE.Vector3(-0.83, FY, 2.32), yaw: 0 },               // напротив, лицом вперёд
      doorMiddle: new THREE.Vector3(HW, FY, 0.5),
    };
    if (assets.busModel) this.useModel(assets.busModel);
  }

  // Две «кожи» борта: снаружи — покраска, внутри — пластик.
  panel(side, y0, y1, z0, z1, outer = this.m.paint) {
    const w = z1 - z0, h = y1 - y0, zc = (z0 + z1) / 2, yc = (y0 + y1) / 2;
    const b = this.shellBatch;
    b.add(new THREE.PlaneGeometry(w, h), matrix(side * HW, yc, zc, 0, side * Math.PI / 2, 0), outer);
    b.add(new THREE.PlaneGeometry(w, h), matrix(side * (HW - 0.05), yc, zc, 0, -side * Math.PI / 2, 0), this.m.inner);
  }

  buildShell() {
    const M = this.m;
    this.shellBatch = new Batcher();
    const b = this.shellBatch;
    // Бока: нижняя часть, полоса, окна со стойками, верх. На правом борту — проёмы дверей.
    for (const side of [-1, 1]) {
      const gaps = side > 0 ? [DOORS.front, DOORS.middle] : [];
      const spans = [];
      let z = -L2;
      for (const g of gaps) { spans.push([z, g.z0]); z = g.z1; }
      spans.push([z, L2]);
      for (const [z0, z1] of spans) {
        if (z1 - z0 < 0.01) continue;
        this.panel(side, 0.28, 0.95, z0, z1);
        this.panel(side, 0.95, WIN_Y0, z0, z1, M.stripe);
        this.panel(side, WIN_Y1, ROOF_Y - 0.06, z0, z1);
        // Стойки окон и стёкла.
        const n = Math.max(1, Math.round((z1 - z0) / 1.45));
        for (let i = 0; i <= n; i++) {
          const zz = z0 + ((z1 - z0) * i) / n;
          b.add(new THREE.BoxGeometry(0.06, WIN_Y1 - WIN_Y0, 0.1), matrix(side * (HW - 0.025), (WIN_Y0 + WIN_Y1) / 2, zz), M.dark);
        }
        const glass = new THREE.Mesh(new THREE.PlaneGeometry(z1 - z0, WIN_Y1 - WIN_Y0), M.glass);
        glass.position.set(side * (HW - 0.02), (WIN_Y0 + WIN_Y1) / 2, (z0 + z1) / 2);
        glass.rotation.y = side * Math.PI / 2;
        glass.renderOrder = 2;
        this.placeholder.add(glass);
      }
      // Над дверями — панель от окон до крыши.
      for (const g of gaps) this.panel(side, 2.35, ROOF_Y - 0.06, g.z0, g.z1);
    }
    // Крыша, пол, потолок, перед, зад.
    b.add(new THREE.BoxGeometry(B.width, 0.08, B.length), matrix(0, ROOF_Y - 0.04, 0), M.paint);
    b.add(new THREE.BoxGeometry(B.width - 0.6, 0.25, 3.2), matrix(0, ROOF_Y + 0.1, 1.5), M.paint); // блок кондиционера
    b.add(new THREE.PlaneGeometry(B.width - 0.1, B.length - 0.1), matrix(0, 2.78, 0, Math.PI / 2), M.ceiling);
    const floor = boxUV(B.width - 0.1, 0.12, B.length - 0.1, 1.2);
    b.add(floor, matrix(0, FY - 0.06, 0), M.floor);
    b.add(new THREE.BoxGeometry(B.width, 0.12, B.length), matrix(0, 0.25, 0), M.dark);       // днище
    // Перед: нижняя панель, лобовое стекло, маршрутоуказатель.
    b.add(new THREE.BoxGeometry(B.width, 0.75, 0.08), matrix(0, 0.62, -L2), M.stripe);
    b.add(new THREE.BoxGeometry(B.width, 0.3, 0.08), matrix(0, 2.9, -L2), M.dark);
    b.add(new THREE.BoxGeometry(B.width + 0.04, 0.12, 0.25), matrix(0, 0.32, -L2 - 0.02), M.dark); // бампер
    const wind = new THREE.Mesh(new THREE.PlaneGeometry(B.width - 0.1, 1.72), M.glass);
    wind.position.set(0, 1.85, -L2 + 0.01);
    wind.rotation.y = Math.PI;
    this.placeholder.add(wind);
    for (const x of [-0.95, 0.95]) {
      b.add(new THREE.BoxGeometry(0.34, 0.14, 0.04), matrix(x, 0.72, -L2 - 0.05), this.m.lightStrip);
    }
    // Зад.
    b.add(new THREE.BoxGeometry(B.width, 1.9, 0.08), matrix(0, 1.25, L2), M.paint);
    b.add(new THREE.BoxGeometry(B.width, 0.38, 0.08), matrix(0, 2.85, L2), M.paint);
    const rear = new THREE.Mesh(new THREE.PlaneGeometry(B.width - 0.3, 0.6), M.glass);
    rear.position.set(0, 2.45, L2 + 0.01);
    this.placeholder.add(rear);
    for (const x of [-1.05, 1.05]) b.add(new THREE.BoxGeometry(0.22, 0.32, 0.05), matrix(x, 0.85, L2 + 0.04), new THREE.MeshStandardMaterial({ color: 0x8a1010, emissive: 0x500000 }));
    // Поворотники (мигают при подъезде к остановке).
    this.indicators = [];
    for (const side of [-1, 1]) {
      for (const z of [-L2 - 0.05, L2 + 0.05]) {
        const m = new THREE.Mesh(new THREE.BoxGeometry(0.18, 0.1, 0.05), M.indicatorOff.clone());
        m.position.set(side * 1.08, 1.0, z);
        this.placeholder.add(m);
        this.indicators.push({ side, mesh: m });
      }
    }
    const shell = b.build({ name: 'bus-shell' });
    this.placeholder.add(shell);
    // Внутри кузова самого себя тени не нужны: иначе салон в полной темноте.
    shell.traverse((o) => { if (o.isMesh) o.castShadow = o.material !== M.ceiling && o.material !== M.inner; });
  }

  seat(b, x, z, yaw = 0) {
    const M = this.m;
    const c = Math.cos(yaw), s = Math.sin(yaw);
    const at = (dx, dz) => [x + dx * c + dz * s, z - dx * s + dz * c];
    const [px, pz] = at(0, 0);
    b.add(new THREE.BoxGeometry(0.44, 0.1, 0.42), matrix(px, FY + 0.45, pz, 0, yaw, 0), M.seat);
    const [bx, bz] = at(0, 0.21);
    // Спинка отклонена назад (Euler XYZ: наклон по X применяется в осях автобуса).
    b.add(new THREE.BoxGeometry(0.44, 0.55, 0.07), matrix(bx, FY + 0.76, bz, Math.cos(yaw) * 0.12, yaw, 0), M.seat);
    b.add(new THREE.BoxGeometry(0.3, 0.4, 0.3), matrix(px, FY + 0.2, pz, 0, yaw, 0), M.shell);
    this.seats.push({ pos: new THREE.Vector3(x, FY, z), yaw, taken: false });
  }

  buildInterior() {
    const M = this.m;
    const b = new Batcher();
    this.seats = [];
    // Слева: пары сидений спереди и сзади; посередине слева — место для коляски.
    for (const z of [-3.9, -3.1, -2.3, -1.5]) for (const x of [-0.98, -0.52]) this.seat(b, x, z);
    for (const z of [2.32, 3.12, 3.92, 4.72]) for (const x of [-0.98, -0.52]) this.seat(b, x, z);
    // Справа: за передней дверью и за средней.
    for (const z of [-3.5, -2.7]) for (const x of [0.52, 0.98]) this.seat(b, x, z);
    for (const z of [2.3, 3.1, 3.9, 4.7]) for (const x of [0.52, 0.98]) this.seat(b, x, z);
    for (const x of [-0.98, -0.5, 0, 0.5, 0.98]) this.seat(b, x, 5.55); // задний ряд
    // Поручни: вертикальные и под потолком.
    const poles = [[0.32, -4.2], [-0.32, -1.1], [0.32, -1.1], [0.32, 1.8], [-0.32, 1.9], [0.32, 3.5], [-0.32, 3.5], [0.32, -0.45], [0.32, 1.45]];
    for (const [x, z] of poles) b.add(new THREE.CylinderGeometry(0.02, 0.02, 2.45, 8), matrix(x, FY + 1.22, z), M.pole);
    for (const x of [-0.45, 0.45]) b.add(new THREE.CylinderGeometry(0.018, 0.018, 10.4, 8), matrix(x, 2.35, 0.3, Math.PI / 2), M.pole);
    // Светильники.
    for (const x of [-0.85, 0.85]) b.add(new THREE.BoxGeometry(0.18, 0.03, 9.8), matrix(x, 2.76, 0.4), M.lightStrip);
    // Площадка для коляски: упор для спины, разметка на полу, пиктограмма, откидное сиденье.
    b.add(new THREE.BoxGeometry(0.62, 0.62, 0.1), matrix(-0.78, FY + 0.95, 0.18), M.blue);
    b.add(new THREE.BoxGeometry(0.05, 1.2, 0.05), matrix(-0.78, FY + 0.6, 0.12), M.pole);
    b.add(new THREE.BoxGeometry(0.9, 0.006, 1.5), matrix(-0.78, FY + 0.003, 0.95), M.blue);
    b.add(new THREE.BoxGeometry(0.4, 0.42, 0.06), matrix(-1.2, FY + 0.95, 1.85, 0, Math.PI / 2, 0), M.shell);
    // Кабина водителя.
    b.add(new THREE.BoxGeometry(1.0, 0.95, 0.06), matrix(-0.78, FY + 0.5, -4.55), M.shell);
    b.add(new THREE.BoxGeometry(2.3, 0.45, 0.6), matrix(0, FY + 0.75, -5.65), M.dark);  // приборная панель
    b.add(new THREE.TorusGeometry(0.22, 0.025, 8, 20), matrix(-0.72, FY + 1.05, -5.15, -1.1), M.dark);
    b.add(new THREE.BoxGeometry(0.5, 0.12, 0.5), matrix(-0.72, FY + 0.5, -4.85), M.dark);
    b.add(new THREE.BoxGeometry(0.5, 0.6, 0.1), matrix(-0.72, FY + 0.85, -4.6), M.dark);
    // Валидатор у средней двери.
    b.add(new THREE.BoxGeometry(0.14, 0.22, 0.1), matrix(0.32, FY + 1.3, 1.4), M.dark);
    const interior = b.build({ name: 'bus-interior' });
    interior.traverse((o) => { o.castShadow = false; });
    this.placeholder.add(interior);

    // Кнопка вызова водителя у места для коляски — до неё дотягивается герой.
    const btnTex = TX.textSign('♿', { w: 128, h: 128, bg: '#1d5fa8', font: 'bold 92px sans-serif' });
    this.stopButton = new THREE.Mesh(new THREE.CylinderGeometry(0.06, 0.06, 0.04, 20), [
      new THREE.MeshStandardMaterial({ color: 0x1d5fa8 }), new THREE.MeshStandardMaterial({ map: btnTex, emissive: 0x000000 }), new THREE.MeshStandardMaterial({ color: 0x1d5fa8 }),
    ]);
    this.stopButton.rotation.z = -Math.PI / 2;
    this.stopButton.position.set(-HW + 0.07, FY + 0.98, 1.25);
    this.stopButton.userData.interact = 'stopButton';
    this.body.add(this.stopButton);
    this.interactables.push(this.stopButton);
    const plate = new THREE.Mesh(new THREE.BoxGeometry(0.03, 0.22, 0.22), M.dark);
    plate.position.set(-HW + 0.04, FY + 0.98, 1.25);
    this.body.add(plate);

    // Свет в салоне.
    for (const z of [-2.2, 2.6]) {
      const l = new THREE.PointLight(0xfff1dc, 3.2, 8, 1.4);
      l.position.set(0, 2.55, z);
      this.body.add(l);
    }
  }

  buildDoors() {
    const M = this.m;
    this.doorLeaves = { front: [], middle: [] };
    for (const [name, d] of Object.entries(DOORS)) {
      const w = (d.z1 - d.z0) / 2;
      for (const k of [0, 1]) {
        const leaf = new THREE.Group();
        const zc = d.z0 + w / 2 + k * w;
        leaf.position.set(HW - 0.03, FY + 1.2, zc);
        leaf.userData = { zc, dir: k ? 1 : -1, w };
        const glass = new THREE.Mesh(new THREE.PlaneGeometry(w - 0.16, 1.7), M.glass);
        glass.position.set(0.03, 0.15, 0);
        glass.rotation.y = Math.PI / 2;
        const top = new THREE.Mesh(new THREE.BoxGeometry(0.05, 0.1, w - 0.02), M.dark);
        top.position.y = 1.1;
        const low = new THREE.Mesh(new THREE.BoxGeometry(0.05, 0.55, w - 0.02), M.paint);
        low.position.y = -0.85;
        const edge1 = new THREE.Mesh(new THREE.BoxGeometry(0.05, 2.3, 0.05), M.dark);
        edge1.position.z = (w - 0.02) / 2;
        const edge2 = edge1.clone();
        edge2.position.z = -(w - 0.02) / 2;
        leaf.add(glass, top, low, edge1, edge2);
        this.placeholder.add(leaf);
        this.doorLeaves[name].push(leaf);
      }
    }
  }

  buildRamp() {
    this.rampPivot = new THREE.Group();
    this.rampPivot.position.set(HW - 0.02, FY + 0.005, 0.5);
    const plate = new THREE.Mesh(boxUV(0.95, 0.04, 0.9, 0.5), this.m.ramp);
    plate.position.set(0.475, 0.02, 0);
    plate.castShadow = true;
    plate.receiveShadow = true;
    const edge = new THREE.Mesh(new THREE.BoxGeometry(0.95, 0.045, 0.04), new THREE.MeshStandardMaterial({ color: 0xf2c230 }));
    edge.position.set(0.475, 0.022, 0.43);
    const edge2 = edge.clone();
    edge2.position.z = -0.43;
    this.rampPivot.add(plate, edge, edge2);
    this.body.add(this.rampPivot);
    this.setRamp(0);
  }

  // 0 — лежит на полу салона, 1 — откинут на тротуар под уклоном.
  setRamp(t) {
    this.rampOut = t;
    const deployed = -Math.atan2(FY - CONFIG.road.curb + 0.02, 0.95);
    this.rampPivot.rotation.z = Math.PI + (deployed - Math.PI) * t;
  }

  buildBoards() {
    this.led = new TX.LedBoard(512, 64);
    this.ledFront = new TX.LedBoard(512, 64);
    const mk = (board, w, h, x, y, z, yaw) => {
      const m = new THREE.Mesh(new THREE.PlaneGeometry(w, h), new THREE.MeshBasicMaterial({ map: board.texture, toneMapped: false }));
      m.position.set(x, y, z);
      m.rotation.y = yaw;
      this.body.add(m);
      return m;
    };
    mk(this.led, 1.3, 0.17, 0, 2.6, -4.2, 0);              // спереди, видно сзади
    mk(this.led, 1.3, 0.17, 0, 2.6, 4.25, Math.PI);         // сзади, видно герою (он лицом назад)
    mk(this.ledFront, 2.1, 0.26, 0, 2.86, -L2 - 0.05, Math.PI);
    const side = mk(this.ledFront, 1.4, 0.18, HW + 0.01, 2.55, -3.6, Math.PI / 2);
    side.scale.x = 1;
    this.ledFront.set(`${STORY.routeNumber}  ${STORY.stops.hospital}`, { color: '#ffb020' });
    // «Остановка по требованию» — загорается после нажатия кнопки.
    this.stopSignTex = TX.textSign('ОСТАНОВКА', { w: 256, h: 64, bg: '#2a0000', fg: '#5a1a1a', font: 'bold 44px sans-serif' });
    this.stopSignOn = TX.textSign('ОСТАНОВКА', { w: 256, h: 64, bg: '#3a0000', fg: '#ff3b30', font: 'bold 44px sans-serif' });
    this.stopSign = new THREE.Mesh(new THREE.PlaneGeometry(0.5, 0.12), new THREE.MeshBasicMaterial({ map: this.stopSignTex, toneMapped: false }));
    this.stopSign.position.set(0, 2.42, 4.25);
    this.stopSign.rotation.y = Math.PI;
    this.body.add(this.stopSign);
  }

  setStopRequested(on) {
    this.stopRequested = on;
    this.stopSign.material.map = on ? this.stopSignOn : this.stopSignTex;
    this.stopButton.material[1].emissive.set(on ? 0x2a6cff : 0x000000);
  }

  buildWheels() {
    for (const z of [-3.3, 3.2]) {
      for (const side of [-1, 1]) {
        const w = new THREE.Group();
        w.position.set(side * (HW - 0.22), 0.5, z);
        const tire = new THREE.Mesh(new THREE.CylinderGeometry(0.5, 0.5, 0.32, 24).rotateZ(Math.PI / 2), this.m.tire);
        const rim = new THREE.Mesh(new THREE.CylinderGeometry(0.3, 0.3, 0.34, 12).rotateZ(Math.PI / 2), this.m.rim);
        tire.castShadow = true;
        w.add(tire, rim);
        this.root.add(w);
        this.wheels.push(w);
      }
      // Арки колёс снаружи.
      for (const side of [-1, 1]) {
        const arch = new THREE.Mesh(new THREE.BoxGeometry(0.06, 0.4, 1.3), this.m.dark);
        arch.position.set(side * (HW + 0.01), 1.0, z);
        this.placeholder.add(arch);
      }
    }
  }

  buildPeople() {
    const r = this.r;
    this.driver = new Human({ name: 'driver', shirt: '#7da6d1', pants: '#2c2c34', hair: '#3b2a20', sitHeight: 0.5 });
    this.driver.root.position.set(-0.72, FY, -4.85);
    this.driver.setMode('sit', true);
    this.driver.armL.sh.rotation.x = 0.9;
    this.body.add(this.driver.root);
    this.passengers = [];
    const shirts = ['#8e5b3c', '#4b7f52', '#a83e3e', '#5d5f9c', '#c79a2a', '#38707a', '#6d6d6d', '#b05f8c'];
    const free = this.seats.filter((s) => !(s.pos.z > 2 && s.pos.z < 2.5 && s.pos.x < 0)); // место мамы
    const picks = [3, 6, 9, 12, 15, 19, 22];
    for (const i of picks) {
      const seat = free[i % free.length];
      if (seat.taken) continue;
      const p = new Human({ name: 'passenger', shirt: r.pick(shirts), pants: r.pick(['#2d2d36', '#3b4a63', '#4a3b2f']), hair: r.pick(['#1e140d', '#4a3020', '#888', '#b8913f']), height: r.range(1.6, 1.82), hairStyle: r() < 0.4 ? 'long' : 'short', sitHeight: 0.5 });
      p.root.position.copy(seat.pos);
      p.root.rotation.y = seat.yaw;
      p.setMode('sit', true);
      p.seat = seat;
      seat.taken = true;
      this.body.add(p.root);
      this.passengers.push(p);
    }
  }

  // Подмена заглушки моделью bus.glb (кузов + салон). Двери и пандус модели
  // анимируются, если в ней есть объекты door_front_*, door_middle_*, ramp.
  useModel(gltf) {
    this.placeholder.visible = false;
    const model = gltf.scene;
    model.traverse((o) => { if (o.isMesh) { o.castShadow = true; o.receiveShadow = true; } });
    this.body.add(model);
    const anchor = (name) => model.getObjectByName(name);
    const wc = anchor('anchor_wheelchair'), mom = anchor('anchor_mom_seat'), door = anchor('anchor_door_middle');
    model.updateMatrixWorld(true);
    if (wc) this.anchors.wheelchair = { pos: wc.getWorldPosition(new THREE.Vector3()).sub(this.root.position), yaw: wc.rotation.y };
    if (mom) this.anchors.mom = { pos: mom.getWorldPosition(new THREE.Vector3()).sub(this.root.position), yaw: mom.rotation.y };
    if (door) this.anchors.doorMiddle = door.getWorldPosition(new THREE.Vector3()).sub(this.root.position);
    this.modelParts = {
      doors: { front: ['door_front_left', 'door_front_right'].map(anchor).filter(Boolean), middle: ['door_middle_left', 'door_middle_right'].map(anchor).filter(Boolean) },
      ramp: anchor('ramp'),
    };
    for (const list of Object.values(this.modelParts.doors)) for (const d of list) d.userData.base = d.position.clone();
    this.driver.root.visible = !anchor('driver');
  }

  // Пассажир встаёт и идёт по точкам (в координатах кузова), затем в мир.
  update(dt, { speed = 0, accel = 0, curvature = 0, time = 0 }) {
    // Подвеска: крен в поворотах, клевок при торможении, мелкая вибрация.
    const lat = speed * speed * curvature;
    // Поворот направо (lat > 0): кузов кренится наружу — правый борт вверх (+rotation.z).
    // Торможение (accel < 0): нос опускается (−rotation.x).
    this.body.rotation.z = THREE.MathUtils.lerp(this.body.rotation.z, lat * 0.012, Math.min(1, dt * 3));
    this.body.rotation.x = THREE.MathUtils.lerp(this.body.rotation.x, accel * 0.012, Math.min(1, dt * 3));
    this.body.position.y = Math.sin(time * 13) * 0.004 * Math.min(1, speed / 6) + Math.sin(time * 2.3) * 0.002;
    for (const w of this.wheels) w.rotation.x -= (speed * dt) / 0.5;

    // Двери: створки выходят наружу и разъезжаются.
    for (const [name, leaves] of Object.entries(this.doorLeaves)) {
      const t = this.doorOpen[name];
      const out = Math.min(1, t * 2), slide = Math.max(0, t * 2 - 1) * 0.92;
      for (const leaf of leaves) {
        const u = leaf.userData;
        leaf.position.x = HW - 0.03 + out * 0.12;
        leaf.position.z = u.zc + u.dir * slide * u.w;
      }
    }
    if (this.modelParts) {
      for (const [name, list] of Object.entries(this.modelParts.doors)) {
        list.forEach((d, i) => d.position.copy(d.userData.base).add(new THREE.Vector3(this.doorOpen[name] * 0.1, 0, (i ? 1 : -1) * this.doorOpen[name] * 0.6)));
      }
      if (this.modelParts.ramp) this.modelParts.ramp.rotation.z = this.rampPivot.rotation.z;
      this.rampPivot.visible = !this.modelParts.ramp;
    }

    // Поворотник: 1.5 Гц.
    const blink = this.indicator && Math.sin(time * Math.PI * 3) > 0;
    for (const ind of this.indicators) ind.mesh.material.emissiveIntensity = blink && ind.side === this.indicator ? 2.5 : 0;

    this.driver.update(dt);
    for (const p of this.passengers) p.update(dt);
  }
}
