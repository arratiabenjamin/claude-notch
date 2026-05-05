# Ideas — Claude Notch

Backlog de features que NO están en el roadmap activo. Cada idea anota
qué la motiva, complejidad estimada, y aprendizaje técnico relevante para
que cuando vuelva al tema (yo o cualquier futuro contribuidor) no tenga
que redescubrir.

---

## Screen saver con orbes Velion en fullscreen

**Qué**: cuando la pantalla del Mac se suspende o el sistema entra en
screen saver, en lugar del fondo estándar de bloqueo aparecen los orbes
Velion ocupando toda la pantalla, en gran tamaño, animados según el
estado de cada sesión activa de Claude Code:

- Orbes orbitando lentamente por la pantalla.
- Pulsado más fuerte y color cálido cuando hay sesiones `running`.
- Brillo/celebración suave cuando una sesión recién terminó.
- Si no hay sesiones activas, un solo orbe respirando en el centro.

**Por qué pega**: convierte el momento muerto del lock screen en
peripheral awareness — alejás el cursor 5 minutos y al volver ya sabés,
de un vistazo, qué está pasando con tus sesiones de Claude Code.
Visualmente memorable; es el tipo de cosa que el resto de la sala mira
de reojo durante una reunión.

### Feasibility técnica

✅ **Factible** vía un *screen saver bundle* (`.saver`) — el mecanismo
oficial de macOS para correr código durante el screen saver. El sistema
NO permite reemplazar el lock screen wallpaper de fondo con animaciones,
pero el screen saver SÍ corre fullscreen con event loop completo.

#### Approach concreto

1. Nuevo target XcodeGen: `ClaudeNotchSaver` con product type
   `com.apple.product-type.bundle.saver`.
2. Subclase `ScreenSaverView` (del framework `ScreenSaver`).
3. Embeber un `NSHostingView` con un nuevo `OrbScreenSaverView` SwiftUI.
   Reusa `VelionOrb` y `SatelliteOrb` directamente.
4. Compartir `Domain/` e `Infrastructure/StateFileWatcher` con la app
   principal vía un Swift package interno o un framework compartido.
5. Render con `TimelineView(.animation)` igual que el orbe del notch —
   mismo lenguaje visual, escalado.

#### Limitaciones a conocer

- **No tiene acceso a Apple Intelligence** salvo que el target tenga el
  entitlement adecuado; el screen saver corre en un contexto sandbox
  más restringido que la app accessory. Para resúmenes hablados quizás
  haya que apoyarse solo en lo que ya escribió la app principal en
  `active-sessions.json`.
- El screen saver no reproduce audio por defecto en algunas configs
  de macOS — habría que setear `AVAudioSession` con cuidado o renunciar
  al TTS en ese contexto.
- Performance crítica: si el orbe consume mucha GPU, el sistema lo
  matará. Mantener el render bajo 16ms por frame.

#### Costo estimado

~1–2 días de trabajo:
- Setup del target + signing → 2h
- Refactor de Domain a un módulo compartido → 4h
- View del saver + lectura del state file → 4h
- Pulido de animaciones fullscreen y testing en sleep/wake → 4h

#### Fuentes a consultar cuando se retome

- Apple docs: ScreenSaver framework
- Ejemplo abierto: Aerial (https://github.com/JohnCoates/Aerial)
- Settings → Screen Saver para verificar registro del bundle

---

## (Plantilla para próximas ideas)

### Título

**Qué**:
**Por qué pega**:
**Feasibility**:
**Approach**:
**Costo**:
