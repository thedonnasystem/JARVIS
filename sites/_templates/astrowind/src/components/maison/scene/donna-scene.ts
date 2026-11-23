// @ts-nocheck -- the vendored three.js build ships without type declarations.
// Maison hero scene, "the Instrument": a gold armillary (polished, satin and wine-lacquered rings, a 72-tick dial and a ring of light) around a
// wine-tinted glass core with a living gold heart. Missed calls stream in from the dark as wine comets, are caught by the rings and turn gold;
// as the page scrolls the same particles reorganise (chaos -> orbit -> flow -> calendar) and gold tiles flip to "booked" with a checkmark.
// Three.js r186 (MIT, vendored in src/vendor/three). Written for this template; attributions in UPSTREAM.md.
import * as THREE from '~/vendor/three/three.module.js';
import { RoundedBoxGeometry } from '~/vendor/three/addons/geometries/RoundedBoxGeometry.js';
import { EffectComposer } from '~/vendor/three/addons/postprocessing/EffectComposer.js';
import { RenderPass } from '~/vendor/three/addons/postprocessing/RenderPass.js';
import { UnrealBloomPass } from '~/vendor/three/addons/postprocessing/UnrealBloomPass.js';
import { OutputPass } from '~/vendor/three/addons/postprocessing/OutputPass.js';
import { ShaderPass } from '~/vendor/three/addons/postprocessing/ShaderPass.js';

// ---------------------------------------------------------------------------------------------------------------------------------- GLSL
// 3D simplex noise: Ian McEwan, Ashima Arts / Stefan Gustavson (MIT), https://github.com/ashima/webgl-noise
const NOISE = `
vec3 mod289(vec3 x){return x-floor(x*(1./289.))*289.;}vec4 mod289(vec4 x){return x-floor(x*(1./289.))*289.;}
vec4 permute(vec4 x){return mod289(((x*34.)+10.)*x);}vec4 taylorInvSqrt(vec4 r){return 1.79284291400159-.85373472095314*r;}
float snoise(vec3 v){const vec2 C=vec2(1./6.,1./3.);const vec4 D=vec4(0.,.5,1.,2.);
vec3 i=floor(v+dot(v,C.yyy));vec3 x0=v-i+dot(i,C.xxx);vec3 g=step(x0.yzx,x0.xyz);vec3 l=1.-g;vec3 i1=min(g.xyz,l.zxy);vec3 i2=max(g.xyz,l.zxy);
vec3 x1=x0-i1+C.xxx;vec3 x2=x0-i2+C.yyy;vec3 x3=x0-D.yyy;i=mod289(i);
vec4 p=permute(permute(permute(i.z+vec4(0.,i1.z,i2.z,1.))+i.y+vec4(0.,i1.y,i2.y,1.))+i.x+vec4(0.,i1.x,i2.x,1.));
float n_=.142857142857;vec3 ns=n_*D.wyz-D.xzx;vec4 j=p-49.*floor(p*ns.z*ns.z);vec4 x_=floor(j*ns.z);vec4 y_=floor(j-7.*x_);
vec4 x=x_*ns.x+ns.yyyy;vec4 y=y_*ns.x+ns.yyyy;vec4 h=1.-abs(x)-abs(y);vec4 b0=vec4(x.xy,y.xy);vec4 b1=vec4(x.zw,y.zw);
vec4 s0=floor(b0)*2.+1.;vec4 s1=floor(b1)*2.+1.;vec4 sh=-step(h,vec4(0.));vec4 a0=b0.xzyw+s0.xzyw*sh.xxyy;vec4 a1=b1.xzyw+s1.xzyw*sh.zzww;
vec3 p0=vec3(a0.xy,h.x);vec3 p1=vec3(a0.zw,h.y);vec3 p2=vec3(a1.xy,h.z);vec3 p3=vec3(a1.zw,h.w);
vec4 norm=taylorInvSqrt(vec4(dot(p0,p0),dot(p1,p1),dot(p2,p2),dot(p3,p3)));p0*=norm.x;p1*=norm.y;p2*=norm.z;p3*=norm.w;
vec4 m=max(.5-vec4(dot(x0,x0),dot(x1,x1),dot(x2,x2),dot(x3,x3)),0.);m=m*m;
return 105.*dot(m*m,vec4(dot(p0,x0),dot(p1,x1),dot(p2,x2),dot(p3,x3)));}`;

const HEART_V = `${NOISE}
uniform float uTime;uniform float uAmp;varying vec3 vN;varying vec3 vV;varying float vD;
void main(){
  float n=snoise(position*2.1+vec3(0.,uTime*.32,uTime*.11));
  float n2=snoise(position*4.6-vec3(uTime*.5))*.4;
  float d=(n+n2)*(.02+.08*uAmp);
  vec3 p=position+normal*d;
  vN=normalize(normalMatrix*normal);vec4 mv=modelViewMatrix*vec4(p,1.);vV=-mv.xyz;vD=d;
  gl_Position=projectionMatrix*mv;}`;
const HEART_F = `
uniform vec3 uGold;uniform vec3 uWine;uniform float uAmp;uniform float uGlow;varying vec3 vN;varying vec3 vV;varying float vD;
void main(){
  float fr=pow(1.-abs(dot(normalize(vN),normalize(vV))),2.2);
  vec3 hot=mix(uGold,vec3(1.,.93,.8),.35);
  vec3 c=mix(uGold*.8+uWine*.2,hot*(1.6+1.6*uAmp),fr)+uGold*max(vD,0.)*10.;
  c+=uGold*.35*pow(1.-fr,6.);
  gl_FragColor=vec4(c*uGlow,1.);}`;

// The particles: every point is one "call" (a comet head plus its trail). Four layouts, blended per particle with a stagger.
const CALL_V = `
attribute vec4 aSeed;attribute float aTrail;attribute vec4 aGrid;
uniform float uTime;uniform float uOrbit;uniform float uFlow;uniform float uGrid;uniform float uBook;uniform float uSize;uniform float uPR;uniform float uIntro;
uniform vec3 uCore;uniform float uCoreScale;uniform vec3 uFlowC;uniform mat4 uCal;uniform vec3 uMissed;uniform vec3 uGold;uniform vec3 uWine;
varying vec3 vCol;varying float vA;
mat3 rx(float a){float c=cos(a),s=sin(a);return mat3(1.,0.,0.,0.,c,s,0.,-s,c);}
mat3 rz(float a){float c=cos(a),s=sin(a);return mat3(c,s,0.,-s,c,0.,0.,0.,1.);}
void main(){
  vec4 s=aSeed;float tr=aTrail;
  // A: a missed call streaming in from the dark and caught by the rings
  float ph=fract(uTime*(.045+.04*s.y)+s.w-tr*.028);
  float e=pow(ph,1.65);
  float a0=s.x*6.2831853;float R=4.5+s.y*7.;
  float d=mix(R,1.62*uCoreScale,e);
  float ang=a0+e*2.4*(s.z>.5?1.:-1.);
  float y0=(s.z-.5)*7.;
  float lx=cos(ang)*d*1.25;lx=lx<0.?lx*.3:lx;
  vec3 pA=uCore+vec3(lx,mix(y0,y0*.04,e),-abs(sin(ang))*d*.75+.15*e);
  float caught=smoothstep(.62,.93,ph);
  float flare=smoothstep(.86,.965,ph)*(1.-smoothstep(.965,1.,ph));
  vec3 cA=mix(uMissed,uGold*2.3,caught)+uGold*flare*3.;
  float aA=smoothstep(0.,.12,ph)*(1.-smoothstep(.955,1.,ph));
  float sA=1.+flare*2.2;
  // B: calls in orbit around the instrument (handled)
  float band=floor(s.x*3.);
  float r=(1.9+band*.34+(s.y-.5)*.2)*uCoreScale;
  float ao=s.z*6.2831853+uTime*(.2-band*.045)*(mod(band,2.)*2.-1.)-tr*.09*(mod(band,2.)*2.-1.);
  vec3 pB=rx(1.2+band*.32)*rz(band*.7-.5)*vec3(cos(ao)*r,(s.w-.5)*.06*uCoreScale,sin(ao)*r)+uCore;
  // C: a ribbon of light (the follow-up pipeline)
  float fx=fract(uTime*.03+s.w-tr*.05);float X=(fx-.5)*20.;float li=floor(s.x*5.);float lane=li/4.-.5;
  vec3 pC=uFlowC+vec3(X,sin(X*.42+uTime*.4+li*1.3)*.13*(.5+abs(lane)*2.)+lane*.1+(s.y-.5)*.02,cos(X*.3+li*1.7)*.4);
  float aC=smoothstep(0.,.12,fx)*(1.-smoothstep(.88,1.,fx));
  // D: the calendar: each call settles on the edge of a tile
  vec3 pD=(uCal*vec4(aGrid.xyz+vec3(0.,0.,.05+.015*sin(uTime*1.7+s.x*40.)),1.)).xyz;
  float booked=step(aGrid.w,uBook);
  float st=s.z*.42;
  float wB=smoothstep(st,st+.58,uOrbit);float wC=smoothstep(st,st+.58,uFlow);float wD=smoothstep(st,st+.58,uGrid);
  vec3 p=mix(pA,pB,wB);p=mix(p,pC,wC);p=mix(p,pD,wD);
  float bul=sin(3.1415926*wB)+sin(3.1415926*wC)+sin(3.1415926*wD);
  p+=(s.xyz-.5)*vec3(.9,.6,.8)*bul;
  vec3 cO=mix(uGold*1.7,mix(uGold,uWine*2.5,.5)*1.3,step(.78,s.y));
  vec3 cD=mix(uGold*.55,uGold*2.1,booked);
  vec3 col=mix(cA,cO,max(wB,wC));col=mix(col,cD,wD);
  float al=mix(aA,1.,max(wB,wD));al=mix(al,aC,wC*(1.-wD));
  float sz=mix(sA,1.,max(max(wB,wC),wD))*mix(1.,.7,wD);
  float tf=1.-tr;
  vA=al*tf*tf*uIntro;
  vCol=col;
  vec4 mv=modelViewMatrix*vec4(p,1.);
  gl_PointSize=min(30.,uSize*sz*(.55+.9*s.y)*(.35+.65*tf)*uPR*(10./max(.5,-mv.z)));
  gl_Position=projectionMatrix*mv;}`;
const CALL_F = `
varying vec3 vCol;varying float vA;
void main(){vec2 c=gl_PointCoord-.5;float d=dot(c,c)*4.;if(d>1.)discard;
  float a=exp(-d*10.)+.22*exp(-d*2.6);a*=1.-d;
  gl_FragColor=vec4(vCol*a*vA,1.);}`;

const BACK_V = `varying vec3 vP;void main(){vP=normalize(position);gl_Position=projectionMatrix*modelViewMatrix*vec4(position,1.);}`;
const BACK_F = `
uniform vec3 uWine;uniform vec3 uGold;uniform float uTime;varying vec3 vP;
void main(){vec3 d=normalize(vP);
  vec3 c=vec3(.0012,.0007,.0008);
  c+=uWine*.32*pow(max(dot(d,normalize(vec3(.75,.6,-1.))),0.),9.);
  c+=uWine*.12*pow(max(dot(d,normalize(vec3(-.9,-.45,-.8))),0.),8.);
  c+=uGold*.02*exp(-abs(d.y+.3)*12.)*smoothstep(-.2,-.9,d.z);
  gl_FragColor=vec4(c,1.);}`;

// vignette, a whisper of chromatic aberration at the edges, film grain and the section dim (after tone mapping, in sRGB)
const FINAL = {
  uniforms: { tDiffuse: { value: null }, uTime: { value: 0 }, uRes: { value: new THREE.Vector2(1, 1) }, uVig: { value: 0.9 }, uGrain: { value: 0.045 } },
  vertexShader: `varying vec2 vUv;void main(){vUv=uv;gl_Position=projectionMatrix*modelViewMatrix*vec4(position,1.);}`,
  fragmentShader: `uniform sampler2D tDiffuse;uniform float uTime;uniform vec2 uRes;uniform float uVig;uniform float uGrain;varying vec2 vUv;
  void main(){vec2 d=vUv-.5;float r=dot(d*vec2(uRes.x/uRes.y,1.),d*vec2(uRes.x/uRes.y,1.));
    float k=.0022*r;vec3 c=vec3(texture2D(tDiffuse,vUv-d*k).r,texture2D(tDiffuse,vUv).g,texture2D(tDiffuse,vUv+d*k).b);
    c*=1.-uVig*smoothstep(.15,1.25,r);
    float g=fract(sin(dot(floor(vUv*uRes)+fract(uTime)*97.,vec2(12.9898,78.233)))*43758.5453);
    c+=(g-.5)*uGrain;
    gl_FragColor=vec4(c,1.);}`,
};

// ---------------------------------------------------------------------------------------------------------------------------------- states
// One state per section (data-scene="..."); the page blends between them as it scrolls. Numbers are world units / radians.
type State = Record<string, number>;
const S = (o: State): State => ({
  ix: 0, iy: 0, iz: 0, is: 1, spread: 1, cx: 0, cy: 0, cz: 8.5, lx: 0, ly: 0, lz: 0,
  orbit: 0, flow: 0, grid: 0, book: 0, fx: 0, fy: 0, fz: -2,
  kx: 0, ky: -7, kz: -3, kr: -1, kt: 0, ks: 0, dim: 1, ...o,
});
const DESK: Record<string, State> = {
  hero: S({ ix: 2.2, iy: 0.02, is: 0.74, spread: 1, lx: 0.25 }),
  call: S({ ix: 1.62, iy: -0.05, iz: -1.6, is: 1.18, spread: 0.12, orbit: 1, cx: 0.2, lx: 0.4, dim: 0.95 }),
  services: S({ ix: 3.7, iy: 1.9, iz: -3.2, is: 0.85, spread: 0.55, orbit: 1, cx: -0.3, cy: 0.3, dim: 0.6 }),
  steps: S({ ix: 4.5, iy: 2.7, iz: -3.6, is: 0.62, spread: 0.3, flow: 1, fy: -0.12, fz: -0.4, cy: 0.1, dim: 0.85 }),
  offer: S({ ix: 3.8, iy: 2.2, iz: -3.4, is: 0.55, spread: 0.2, grid: 1, book: 0.3, cy: 1.1, ly: -0.5, ky: -2.35, kz: -1.2, kr: -1.3, kt: 0.0, ks: 1.25, dim: 0.85 }),
  pricing: S({ ix: 4.4, iy: 2.9, iz: -4, is: 0.5, spread: 0.15, grid: 1, book: 1.02, cy: 1.4, ly: -0.6, kx: 0.3, ky: -3.0, kz: -3.6, kr: -1.36, kt: 0.1, ks: 1.1, dim: 0.48 }),
  results: S({ ix: 5.0, iy: 2.9, iz: -4.5, is: 0.6, spread: 0.35, orbit: 1, grid: 0.4, book: 1.02, cy: 1.8, ly: -0.6, kx: 0, ky: -5.0, kz: -4.5, kr: -1.38, kt: -0.06, ks: 1.3, dim: 0.42 }),
  faq: S({ ix: -2.95, iy: -1.0, iz: -1.2, is: 0.82, spread: 0.7, orbit: 1, book: 1.02, dim: 0.62 }),
  contact: S({ ix: -2.7, iy: -1.35, iz: -1.4, is: 0.9, spread: 0.18, orbit: 1, book: 1.02, dim: 0.65 }),
};
const MOB: Record<string, State> = {
  hero: S({ iy: 1.66, is: 0.66, spread: 1, cz: 9.5, ly: 0.15 }),
  call: S({ iy: 0.2, iz: -2.2, is: 1.05, spread: 0.12, orbit: 1, cz: 9.5, dim: 0.6 }),
  services: S({ ix: 1.7, iy: 3.7, iz: -4, is: 0.7, spread: 0.55, orbit: 1, cz: 9.5, dim: 0.42 }),
  steps: S({ ix: 1.7, iy: 3.7, iz: -4, is: 0.6, spread: 0.3, flow: 1, fy: 0.4, fz: -3, cz: 9.5, dim: 0.5 }),
  offer: S({ ix: 1.7, iy: 3.8, iz: -4, is: 0.5, grid: 1, book: 0.3, cz: 9.5, cy: 1.2, ly: -0.5, ky: -2.9, kz: -2.0, kr: -1.25, ks: 0.8, dim: 0.55 }),
  pricing: S({ ix: 1.7, iy: 3.9, iz: -4, is: 0.45, grid: 1, book: 1.02, cz: 9.5, cy: 1.6, ly: -0.7, ky: -3.2, kz: -3.2, kr: -1.3, kt: 0.12, ks: 0.85, dim: 0.4 }),
  results: S({ ix: 0, iy: 2.6, iz: -8, is: 1.0, orbit: 1, grid: 0.3, book: 1.02, cy: 2, ly: -0.9, ky: -6.5, kz: -6, kr: -1.3, ks: 0.85, cz: 9.5, dim: 0.36 }),
  faq: S({ ix: -1.4, iy: -3.4, iz: -5, is: 0.8, spread: 0.7, orbit: 1, book: 1.02, cz: 9.5, dim: 0.34 }),
  contact: S({ iy: -2.5, iz: -3.2, is: 1.0, spread: 0.18, orbit: 1, book: 1.02, cz: 9.5, dim: 0.42 }),
};

const ease = (t: number) => t * t * t * (t * (t * 6 - 15) + 10);
const clamp01 = (x: number) => Math.min(1, Math.max(0, x));
const damp = (a: number, b: number, k: number, dt: number) => a + (b - a) * (1 - Math.exp(-k * dt));

// ---------------------------------------------------------------------------------------------------------------------------------- mount
export interface Options { gold: number[]; wine: number[]; mobile: boolean; reduce: boolean; manual?: boolean; post?: boolean; onTier?: (t: number) => void; }

export function mount(canvas: HTMLCanvasElement, o: Options) {
  const mobile = o.mobile;
  let tier = o.post === false ? 1 : o.post ? 2 : mobile ? 1 : 2; // 2: bloom + MSAA + glass transmission; 1: direct render, cheaper glass; 0: still frame only
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: tier === 1, alpha: false, stencil: false, powerPreference: 'high-performance' });
  renderer.setClearColor(0x030202, 1);
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.05;
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  let dprCap = mobile ? 1.25 : 1.5;
  const dpr = () => Math.min(window.devicePixelRatio || 1, dprCap);
  renderer.setPixelRatio(dpr());

  const gold = new THREE.Color().setRGB(o.gold[0], o.gold[1], o.gold[2], THREE.SRGBColorSpace);
  const wine = new THREE.Color().setRGB(o.wine[0], o.wine[1], o.wine[2], THREE.SRGBColorSpace);
  const goldV = new THREE.Vector3(gold.r, gold.g, gold.b);
  const wineV = new THREE.Vector3(wine.r, wine.g, wine.b);

  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(mobile ? 40 : 32, 1, 0.1, 120);

  // studio environment for the reflections: a dark room with warm softboxes, a cool rim strip and a wine wall, prefiltered by PMREM
  // (approach of three.js RoomEnvironment, MIT; no HDR file is downloaded)
  {
    const env = new THREE.Scene();
    const box = new THREE.BoxGeometry(1, 1, 1);
    const room = new THREE.Mesh(box, new THREE.MeshBasicMaterial({ color: 0x0a0607, side: THREE.BackSide }));
    room.scale.set(24, 14, 24);
    env.add(room);
    const light = (c: THREE.Color, k: number, p: number[], sc: number[], ry = 0, rx = 0) => {
      const m = new THREE.Mesh(box, new THREE.MeshBasicMaterial({ color: c.clone().multiplyScalar(k) }));
      m.position.set(p[0], p[1], p[2]);
      m.scale.set(sc[0], sc[1], sc[2]);
      m.rotation.set(rx, ry, 0);
      env.add(m);
    };
    const warm = new THREE.Color(1, 0.86, 0.66), cool = new THREE.Color(0.85, 0.9, 1);
    light(warm, 5, [0, 6.6, 0], [9, 0.1, 6]); // overhead softbox
    light(warm, 14, [-8, 1, 2], [0.1, 9, 1.3]); // key strip
    light(cool, 9, [8.5, 0.5, -1], [0.1, 8, 0.7]); // rim strip
    light(wine, 2.6, [0, 0, -11.5], [16, 7, 0.1]); // wine wall behind
    light(gold.clone(), 2.2, [0, -6.6, 2], [12, 0.1, 4]); // gold floor bounce
    light(warm, 40, [3, 3, 10], [1.2, 1.2, 0.1]); // small hot spot (catchlight)
    light(warm, 30, [-4, 4.5, 8], [0.6, 2.4, 0.1]);
    const pm = new THREE.PMREMGenerator(renderer);
    scene.environment = pm.fromScene(env, 0.025).texture;
    pm.dispose();
    env.traverse((m: any) => { m.geometry?.dispose?.(); m.material?.dispose?.(); });
  }

  const backdrop = new THREE.Mesh(new THREE.SphereGeometry(60, 32, 16),
    new THREE.ShaderMaterial({ vertexShader: BACK_V, fragmentShader: BACK_F, side: THREE.BackSide, depthWrite: false,
      uniforms: { uWine: { value: wineV }, uGold: { value: goldV }, uTime: { value: 0 } } }));
  backdrop.renderOrder = -10;
  scene.add(backdrop);

  // ----- the instrument
  const inst = new THREE.Group();
  scene.add(inst);
  const polished = new THREE.MeshPhysicalMaterial({ color: gold, metalness: 1, roughness: 0.16, clearcoat: 0.7, clearcoatRoughness: 0.06, envMapIntensity: 1.35 });
  const satin = new THREE.MeshPhysicalMaterial({ color: gold.clone().lerp(new THREE.Color(1, 0.9, 0.7), 0.12), metalness: 1, roughness: 0.34, envMapIntensity: 1.2 });
  const lacquer = new THREE.MeshPhysicalMaterial({ color: wine.clone().multiplyScalar(1.05), metalness: 0.6, roughness: 0.22, clearcoat: 1, clearcoatRoughness: 0.03, envMapIntensity: 1.3 });
  const lightMat = new THREE.MeshBasicMaterial({ color: gold.clone().multiplyScalar(2.4), toneMapped: true });

  const seg = mobile ? 180 : 320;
  const ring = (r: number, t: number, m: THREE.Material, arc = Math.PI * 2) => new THREE.Mesh(new THREE.TorusGeometry(r, t, 24, seg, arc), m);
  const gA = new THREE.Group(), gB = new THREE.Group(), gC = new THREE.Group(), gD = new THREE.Group();
  inst.add(gA, gB, gC, gD);
  gA.add(ring(1.6, 0.026, polished));
  gA.add(ring(1.53, 0.006, satin));
  { // the dial: 72 ticks, every sixth one long
    const tick = new THREE.BoxGeometry(0.014, 1, 0.024);
    const ticks = new THREE.InstancedMesh(tick, satin, 72);
    const m = new THREE.Matrix4(), q = new THREE.Quaternion(), v = new THREE.Vector3(), sc = new THREE.Vector3();
    for (let i = 0; i < 72; i++) {
      const a = (i / 72) * Math.PI * 2, long = i % 6 === 0, len = long ? 0.16 : 0.07, r = 1.48 - len / 2;
      q.setFromAxisAngle(new THREE.Vector3(0, 0, 1), a - Math.PI / 2);
      v.set(Math.cos(a) * r, Math.sin(a) * r, 0);
      sc.set(long ? 1.6 : 1, len, 1);
      ticks.setMatrixAt(i, m.compose(v, q, sc));
    }
    gA.add(ticks);
  }
  gB.add(ring(1.3, 0.036, satin));
  { // three beads riding the satin ring, like the jewels of a movement
    const bead = new THREE.SphereGeometry(0.06, 24, 16);
    for (let i = 0; i < 3; i++) { const b = new THREE.Mesh(bead, polished); const a = i * 2.094 + 0.4; b.position.set(Math.cos(a) * 1.3, Math.sin(a) * 1.3, 0); gB.add(b); }
  }
  gC.add(ring(1.08, 0.02, lacquer));
  const halo = ring(1.92, 0.004, lightMat);
  const arc1 = ring(2.02, 0.008, lightMat, Math.PI * 0.55);
  const arc2 = ring(2.02, 0.008, lightMat, Math.PI * 0.22);
  arc2.rotation.z = Math.PI * 1.1;
  gD.add(halo, arc1, arc2);

  // the core: a brilliant-cut crystal (real transmission + dispersion on capable GPUs, a reflective faceted glass otherwise) around a gold heart
  const glassHi = () => new THREE.MeshPhysicalMaterial({ color: 0xffffff, metalness: 0, roughness: 0, transmission: 1, thickness: 0.9, ior: 2.1, dispersion: 3,
    attenuationColor: new THREE.Color(1, 0.86, 0.84), attenuationDistance: 3, specularIntensity: 1, envMapIntensity: 1.8, flatShading: true });
  const glassLo = () => new THREE.MeshPhysicalMaterial({ color: gold.clone().lerp(new THREE.Color(1, 0.95, 0.9), 0.5), metalness: 0.85, roughness: 0.04, transparent: true, opacity: 0.5,
    envMapIntensity: 1.8, flatShading: true, depthWrite: false });
  const cut = [[0.001, -0.78], [0.12, -0.62], [0.8, 0.06], [0.8, 0.12], [0.5, 0.38], [0.001, 0.4]].map(([x, y]) => new THREE.Vector2(x, y));
  const core = new THREE.Mesh(new THREE.LatheGeometry(cut, 20), tier === 2 ? glassHi() : glassLo());
  core.scale.setScalar(0.92);
  core.renderOrder = 2;
  inst.add(core);
  const heartU = { uTime: { value: 0 }, uAmp: { value: 0 }, uGold: { value: goldV }, uWine: { value: wineV }, uGlow: { value: 1 } };
  const heart = new THREE.Mesh(new THREE.IcosahedronGeometry(0.2, mobile ? 16 : 28), new THREE.ShaderMaterial({ vertexShader: HEART_V, fragmentShader: HEART_F, uniforms: heartU }));
  inst.add(heart);
  const cursorLight = new THREE.PointLight(new THREE.Color(1, 0.85, 0.6), 0, 7, 2);
  scene.add(cursorLight);

  // ----- the calendar: 7 x 5 tiles; 26 of them get booked, one after another
  const COLS = 7, ROWS = 5, T = 0.56, GAP = 0.1, N = COLS * ROWS;
  const cal = new THREE.Group();
  scene.add(cal);
  const tileMat = new THREE.MeshPhysicalMaterial({ color: 0xffffff, metalness: 0.9, roughness: 0.36, clearcoat: 0.8, clearcoatRoughness: 0.12, envMapIntensity: 0.95 });
  const tiles = new THREE.InstancedMesh(new RoundedBoxGeometry(T, T, 0.07, 3, 0.07), tileMat, N);
  const checkCurve = new THREE.CatmullRomCurve3([new THREE.Vector3(-0.13, 0.0, 0), new THREE.Vector3(-0.04, -0.09, 0), new THREE.Vector3(0.15, 0.12, 0)], false, 'catmullrom', 0.05);
  const checks = new THREE.InstancedMesh(new THREE.TubeGeometry(checkCurve, 24, 0.016, 8, false), new THREE.MeshBasicMaterial({ color: gold.clone().multiplyScalar(4) }), N);
  cal.add(tiles, checks);
  const tilePos: THREE.Vector3[] = [], order: number[] = [];
  let rnd = 0x9e3779b9; // mulberry32: a small PRNG without the lattice artefacts of a plain LCG (those showed up as dotted lines in the dust)
  const rand = () => { rnd = (rnd + 0x6d2b79f5) | 0; let t = Math.imul(rnd ^ (rnd >>> 15), 1 | rnd); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
  const bookList: number[] = [];
  for (let i = 0; i < N; i++) {
    const c = i % COLS, r = Math.floor(i / COLS);
    tilePos.push(new THREE.Vector3((c - (COLS - 1) / 2) * (T + GAP), ((ROWS - 1) / 2 - r) * (T + GAP), 0));
    order.push(2);
    if (rand() < 0.76) bookList.push(i);
  }
  bookList.sort(() => rand() - 0.5).forEach((i, k) => { order[i] = (k + 0.5) / bookList.length; });
  const ink = new THREE.Color(0x1d1416), tmpC = new THREE.Color(), tm = new THREE.Matrix4(), tq = new THREE.Quaternion(), te = new THREE.Euler(), tv = new THREE.Vector3(), ts = new THREE.Vector3();
  let lastBook = -1;
  const setBooking = (b: number, t: number) => {
    if (Math.abs(b - lastBook) < 0.0005 && b > 1) return;
    lastBook = b;
    for (let i = 0; i < N; i++) {
      const k = order[i] > 1 ? 0 : clamp01((b - order[i]) * 7);
      const f = ease(k);
      te.set(f * Math.PI, 0, 0);
      tq.setFromEuler(te);
      tv.copy(tilePos[i]);
      tv.z += Math.sin(f * Math.PI) * 0.35;
      tiles.setMatrixAt(i, tm.compose(tv, tq, ts.set(1, 1, 1)));
      tiles.setColorAt(i, tmpC.copy(ink).lerp(gold, f > 0.5 ? 0.85 : 0));
      const cs = clamp01((k - 0.75) * 4);
      tv.copy(tilePos[i]);
      tv.z += 0.05;
      checks.setMatrixAt(i, tm.compose(tv, tq.identity(), ts.setScalar(Math.max(0.0001, ease(cs)))));
    }
    tiles.instanceMatrix.needsUpdate = true;
    tiles.instanceColor.needsUpdate = true;
    checks.instanceMatrix.needsUpdate = true;
  };
  setBooking(0, 0);
  // booked tiles turn to polished gold, open ones stay dark lacquer
  tileMat.onBeforeCompile = () => {};

  // ----- the calls
  const CALLS = mobile ? 110 : 280, TRAIL = mobile ? 9 : 14, P = CALLS * TRAIL;
  const seeds = new Float32Array(P * 4), trail = new Float32Array(P), grid = new Float32Array(P * 4), pos = new Float32Array(P * 3);
  for (let c = 0; c < CALLS; c++) {
    const s = [rand(), rand(), rand(), rand()];
    const tile = c % N;
    const u = rand() * 4, side = Math.floor(u), f = u - side, h = T / 2 + 0.02;
    const ex = side === 0 ? -h + f * 2 * h : side === 1 ? h : side === 2 ? h - f * 2 * h : -h;
    const ey = side === 0 ? h : side === 1 ? h - f * 2 * h : side === 2 ? -h : -h + f * 2 * h;
    for (let t = 0; t < TRAIL; t++) {
      const i = c * TRAIL + t;
      seeds.set(s, i * 4);
      trail[i] = t / TRAIL;
      grid.set([tilePos[tile].x + ex, tilePos[tile].y + ey, 0, order[tile]], i * 4);
    }
  }
  const pg = new THREE.BufferGeometry();
  pg.setAttribute('position', new THREE.BufferAttribute(pos, 3));
  pg.setAttribute('aSeed', new THREE.BufferAttribute(seeds, 4));
  pg.setAttribute('aTrail', new THREE.BufferAttribute(trail, 1));
  pg.setAttribute('aGrid', new THREE.BufferAttribute(grid, 4));
  pg.boundingSphere = new THREE.Sphere(new THREE.Vector3(), 100);
  const callU = {
    uTime: { value: 0 }, uOrbit: { value: 0 }, uFlow: { value: 0 }, uGrid: { value: 0 }, uBook: { value: 0 }, uSize: { value: mobile ? 6 : 5.5 }, uPR: { value: dpr() },
    uIntro: { value: 0 }, uCore: { value: new THREE.Vector3() }, uCoreScale: { value: 1 }, uFlowC: { value: new THREE.Vector3() }, uCal: { value: new THREE.Matrix4() },
    uMissed: { value: new THREE.Vector3(1.0, 0.06, 0.13).multiplyScalar(1.7) }, uGold: { value: goldV }, uWine: { value: wineV },
  };
  const calls = new THREE.Points(pg, new THREE.ShaderMaterial({ vertexShader: CALL_V, fragmentShader: CALL_F, uniforms: callU, transparent: true, depthWrite: false, blending: THREE.AdditiveBlending }));
  calls.frustumCulled = false;
  calls.renderOrder = 3;
  scene.add(calls);

  // fine gold dust for depth (static, slow parallax)
  {
    const D = mobile ? 260 : 700, dp = new Float32Array(D * 3);
    for (let i = 0; i < D; i++) dp.set([(rand() - 0.5) * 34, (rand() - 0.5) * 20, -4 - rand() * 22], i * 3);
    const dg = new THREE.BufferGeometry();
    dg.setAttribute('position', new THREE.BufferAttribute(dp, 3));
    const dust = new THREE.Points(dg, new THREE.PointsMaterial({ color: gold.clone().multiplyScalar(0.55), size: mobile ? 0.05 : 0.04, sizeAttenuation: true, transparent: true, opacity: 0.6, depthWrite: false, blending: THREE.AdditiveBlending }));
    dust.renderOrder = 1;
    scene.add(dust);
  }

  // ----- post
  let composer: any = null, bloom: any = null, finalPass: any = null;
  const buildComposer = () => {
    const rt = new THREE.WebGLRenderTarget(1, 1, { type: THREE.HalfFloatType, samples: 4 });
    composer = new EffectComposer(renderer, rt);
    composer.addPass(new RenderPass(scene, camera));
    bloom = new UnrealBloomPass(new THREE.Vector2(256, 256), 0.5, 0.28, 0.92);
    composer.addPass(bloom);
    composer.addPass(new OutputPass());
    finalPass = new ShaderPass(FINAL);
    composer.addPass(finalPass);
  };
  if (tier === 2) buildComposer();

  // ----- sections, scroll, pointer
  const sections = Array.from(document.querySelectorAll<HTMLElement>('[data-scene]'));
  let keys: number[] = [], names: string[] = [];
  const measure = () => {
    const vh = window.innerHeight;
    keys = [];
    names = [];
    sections.forEach((el, i) => {
      const r = el.getBoundingClientRect(), top = r.top + window.scrollY;
      const k = i === 0 ? 0 : Math.max(top - vh * 0.25, top + r.height / 2 - vh / 2);
      keys.push(Math.max(k, keys.length ? keys[keys.length - 1] + 1 : 0));
      names.push(el.dataset.scene || 'hero');
    });
  };
  const table = () => (mobile ? MOB : DESK);
  const target = { ...DESK.hero };
  const cur = { ...table().hero };
  const sample = (y: number) => {
    const tb = table();
    if (!keys.length) return Object.assign(target, tb.hero);
    let i = 0;
    while (i < keys.length - 1 && y >= keys[i + 1]) i++;
    const a = tb[names[i]] || tb.hero, b = tb[names[Math.min(i + 1, names.length - 1)]] || a;
    const f = i >= keys.length - 1 ? 0 : ease(clamp01((y - keys[i]) / (keys[i + 1] - keys[i])));
    for (const k in a) target[k] = a[k] + (b[k] - a[k]) * f;
    return target;
  };

  const pointer = { x: 0, y: 0, tx: 0, ty: 0, px: -9, py: -9 };
  const fine = window.matchMedia('(pointer: fine)').matches;
  const onMove = (e: PointerEvent) => { pointer.tx = (e.clientX / innerWidth) * 2 - 1; pointer.ty = -((e.clientY / innerHeight) * 2 - 1); };
  const onTilt = (e: DeviceOrientationEvent) => { if (e.gamma == null || e.beta == null) return; pointer.tx = Math.max(-1, Math.min(1, e.gamma / 30)); pointer.ty = Math.max(-1, Math.min(1, (45 - e.beta) / 30)); };
  if (!o.reduce) {
    if (fine) window.addEventListener('pointermove', onMove, { passive: true });
    else window.addEventListener('deviceorientation', onTilt, { passive: true });
  }
  let amp = 0, ampT = 0;
  const onVoice = (e: Event) => { ampT = (e as CustomEvent).detail || 0; };
  window.addEventListener('m:voice', onVoice);

  let W = 0, H = 0;
  const resize = () => {
    W = canvas.clientWidth || innerWidth;
    H = canvas.clientHeight || innerHeight;
    const pr = dpr();
    renderer.setPixelRatio(pr);
    renderer.setSize(W, H, false);
    camera.aspect = W / H;
    camera.updateProjectionMatrix();
    callU.uPR.value = pr * (H / 900);
    if (composer) {
      composer.setPixelRatio(pr);
      composer.setSize(W, H);
      bloom.resolution.set(W * pr * 0.5, H * pr * 0.5);
      finalPass.uniforms.uRes.value.set(W * pr, H * pr);
    }
    measure();
  };
  resize();
  const ro = new ResizeObserver(() => measure());
  ro.observe(document.body);
  window.addEventListener('resize', resize);

  // ----- frame
  let time = 4, intro = o.reduce ? 1 : 0, scrollV = 0, lastY = window.scrollY, spin = 0;
  const look = new THREE.Vector3(), calM = new THREE.Matrix4();
  const update = (dt: number) => {
    time += dt;
    intro = Math.min(1, intro + dt / 2.6);
    const y = window.scrollY;
    scrollV = damp(scrollV, (y - lastY) / Math.max(dt, 1 / 120), 6, dt);
    lastY = y;
    const tg = sample(y);
    const k = o.reduce ? 1e3 : 3.2;
    for (const key in tg) cur[key] = damp(cur[key] ?? tg[key], tg[key], key === 'book' ? 2.2 : k, dt);
    if (!fine && !o.reduce && !pointer.tx && !pointer.ty) { pointer.tx = Math.sin(time * 0.21) * 0.5; pointer.ty = Math.cos(time * 0.17) * 0.35; }
    pointer.x = damp(pointer.x, pointer.tx, 3, dt);
    pointer.y = damp(pointer.y, pointer.ty, 3, dt);
    amp = damp(amp, ampT * (0.55 + 0.45 * Math.sin(time * 11) * Math.sin(time * 3.7)), 10, dt);

    const ie = ease(intro);
    // camera: section framing + pointer parallax + a slow breathing drift
    camera.position.set(cur.cx + pointer.x * 0.45 + Math.sin(time * 0.11) * 0.12, cur.cy + pointer.y * 0.28 + Math.cos(time * 0.09) * 0.08, cur.cz + (1 - ie) * 2.2);
    look.set(cur.lx + pointer.x * 0.1, cur.ly + pointer.y * 0.06, cur.lz);
    camera.lookAt(look);

    // instrument: position, scale, ring choreography (spread 1 = gyroscope, 0 = concentric dial facing the viewer)
    inst.position.set(cur.ix, cur.iy + Math.sin(time * 0.6) * 0.04, cur.iz);
    const s = cur.is * (0.82 + 0.18 * ie);
    inst.scale.setScalar(s);
    spin += dt * (0.18 + Math.min(2.5, Math.abs(scrollV) / 900));
    const sp = cur.spread * (0.4 + 0.6 * ie);
    inst.rotation.set(-0.12 + pointer.y * 0.12, -0.25 + pointer.x * 0.22, 0.05);
    gA.rotation.set(sp * 1.05, sp * 0.35 + Math.sin(spin * 0.4) * 0.12 * sp, spin * 0.12);
    gB.rotation.set(sp * -0.55 + Math.sin(spin * 0.5) * 0.25 * sp, sp * 1.25, -spin * 0.2);
    gC.rotation.set(sp * 0.35, sp * -0.9 + Math.cos(spin * 0.45) * 0.3 * sp, spin * 0.33);
    gD.rotation.set(sp * 1.35 + 0.15, sp * 0.15, spin * 0.5);
    heart.rotation.y = time * 0.25;
    core.rotation.set(0.32, time * 0.22, 0.12);
    heart.scale.setScalar(1 + amp * 0.25);
    heartU.uTime.value = time;
    heartU.uAmp.value = amp;
    heartU.uGlow.value = 0.25 + 0.75 * ie;

    cursorLight.position.set(cur.ix + pointer.x * 2.6, cur.iy + pointer.y * 1.8, cur.iz + 2.2);
    cursorLight.intensity = fine ? 6 * ie : 0;

    // calendar
    cal.visible = cur.ks > 0.02;
    cal.position.set(cur.kx, cur.ky, cur.kz);
    cal.rotation.set(cur.kr + pointer.y * 0.05, pointer.x * 0.06, cur.kt);
    cal.scale.setScalar(Math.max(0.0001, cur.ks));
    if (cal.visible) setBooking(cur.book, time);
    cal.updateMatrixWorld();
    calM.copy(cal.matrixWorld);
    if (!cal.visible) calM.makeTranslation(0, -6, -4);

    callU.uTime.value = time;
    callU.uOrbit.value = cur.orbit;
    callU.uFlow.value = cur.flow;
    callU.uGrid.value = cur.grid;
    callU.uBook.value = cur.book;
    callU.uIntro.value = ie;
    callU.uCore.value.copy(inst.position);
    callU.uCoreScale.value = s;
    callU.uFlowC.value.set(cur.fx, cur.fy, cur.fz);
    callU.uCal.value.copy(calM);

    renderer.toneMappingExposure = 1.05 * cur.dim * (0.15 + 0.85 * ie);
    if (finalPass) finalPass.uniforms.uTime.value = time;
    if (bloom) bloom.strength = 0.5 * (0.6 + 0.4 * cur.dim);
  };
  const draw = () => { if (composer && tier === 2) composer.render(); else renderer.render(scene, camera); };

  // ----- adaptive quality: watch the frame time, step down (bloom -> resolution -> particle count -> stop) on slow GPUs
  let frames = 0, acc = 0, stopped = false, running = false, raf = 0, last = 0, prevNow = 0;
  const degrade = () => {
    if (tier === 2) {
      tier = 1;
      core.material.dispose();
      core.material = glassLo();
      dprCap = Math.min(dprCap, 1.15);
      resize();
    } else if (dprCap > 0.8) {
      dprCap = 0.75;
      pg.setDrawRange(0, Math.floor(P / 2));
      resize();
    } else { stopped = true; }
    o.onTier?.(stopped ? 0 : tier);
  };
  const loop = (now: number) => {
    raf = 0;
    if (!running) return;
    const dt = Math.min(0.05, (now - last) / 1000 || 0.016);
    last = now;
    update(dt);
    draw();
    frames++;
    if (frames > 10) {
      acc += (now - prevNow) / 1000;
      if (frames % 30 === 0) {
        const avg = acc / 30;
        acc = 0;
        if (avg > 0.075) { stopped = true; o.onTier?.(0); } // far too slow (software GL, a struggling phone): keep the still frame
        else if (avg > (tier === 2 ? 0.024 : 0.032)) degrade();
      }
    }
    prevNow = now;
    if (!stopped) raf = requestAnimationFrame(loop);
  };
  const play = () => { if (running || stopped || o.reduce || o.manual) return; running = true; last = prevNow = performance.now(); raf = requestAnimationFrame(loop); };
  const pause = () => { running = false; if (raf) cancelAnimationFrame(raf); raf = 0; };
  const onVis = () => (document.hidden ? pause() : play());
  document.addEventListener('visibilitychange', onVis);

  // first frame (also the whole show under prefers-reduced-motion: one still, fully composed frame)
  if (o.reduce) { update(0.016); draw(); }
  else { update(0.016); draw(); play(); }

  return {
    renderStill() { update(0.016); draw(); },
    get tier() { return stopped ? 0 : tier; },
    // capture hook for previews/recordings: advance the scene clock deterministically
    step(dt: number, render = true) { update(dt); if (render) draw(); },
    pause, play,
    get state() { return { ...cur, keys, names }; },
  };
}
