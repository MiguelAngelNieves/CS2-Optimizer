# CS2 Optimizer

**Optimiza Counter-Strike 2 en tu PC midiendo, no adivinando.**
Escanea tu equipo, propone una configuración según tu hardware, la aplica con respaldo y te deja comparar pruebas reales (FPS y temperaturas) con HWiNFO.

> 🇬🇧 English version below.

---

## ¿Por qué?

Las guías de YouTube dan la misma lista para todos. CS2 Optimizer:

- **Detecta tu equipo**: CPU, GPU (NVIDIA / AMD / Intel), RAM y canales, disco, portátil o escritorio, monitor.
- **Recomienda** resolución, calidad y límite de FPS según el nivel de tu GPU.
- **Mide de verdad**: analiza el registro de HWiNFO (FPS, 1% low, temperatura de CPU/GPU, *throttling*) y compara tus pruebas.
- **Te dice cuál es el mejor equilibrio** para *tu* PC: FPS altos con la CPU más fresca.

Caso real (portátil ASUS TUF, i5-9300H + GTX 1650): de tener que limitar el juego a 30 FPS con todo al mínimo y la GPU recalentada, a **60+ FPS estables con la GPU a ~58 °C** a 1600×900.

## Seguridad (VAC)

- ✅ Solo toca **archivos de configuración** (`cs2_video.txt`, `autoexec.cfg`, opciones de lanzamiento) y **ajustes de Windows** (energía de CPU, reloj de GPU NVIDIA, Game DVR).
- ✅ **Nunca** modifica archivos del juego, no inyecta nada y no se ejecuta dentro de CS2.
- ✅ **Respaldo automático** de todo la primera vez y botón **Restaurar todo**.

## Requisitos

- Windows 10 / 11
- CS2 abierto **al menos una vez** (para que exista su configuración)
- Opcional (recomendado): [HWiNFO64](https://www.hwinfo.com/download/) para medir temperaturas y FPS

## Uso

1. Descarga el repositorio (**Code → Download ZIP**) y descomprímelo.
2. Doble clic en **`Iniciar.bat`** y acepta el permiso de administrador (necesario para los ajustes de CPU/GPU).
3. **Pestaña 1 – Escaneo**: revisa tu equipo y la recomendación → **Usar recomendación**.
4. **Pestaña 2 – Ajustes**: cierra CS2 (y Steam, para las opciones de lanzamiento) → **APLICAR**.
5. **Pestaña 3 – Medir y comparar**:
   1. Abre HWiNFO64 → *Sensores* → botón verde **“+”** (iniciar registro) → guarda el CSV.
   2. Juega ~10 minutos (siempre el mismo modo/mapa para comparar).
   3. Detén el registro → **Analizar CSV de HWiNFO** → ponle nombre a la prueba.
6. Cambia **una sola cosa** (resolución, límite de FPS, CPU sin turbo…), repite y compara. La tabla te marca el **mejor equilibrio**.

¿Algo raro? **Exportar diagnóstico** crea un `.zip` en el Escritorio para adjuntarlo en un *issue*.

## Qué ajusta

| Área | Ajuste |
|---|---|
| Gráficos | Resolución (incluye 4:3), calidad mínima competitiva, FSR, DirectX 11 / Vulkan |
| Juego | `fps_max`, `fps_max_ui`, contador de FPS, quitar “contraste de jugadores” |
| Lanzamiento | `+exec autoexec`, `-vulkan`, quitar `-allow_third_party_software` (conserva tus otras opciones) |
| CPU | Turbo activado / desactivado o tope de 3.0 / 3.5 GHz (menos calor en portátiles) |
| GPU (NVIDIA) | Límite de reloj máximo (efecto parecido a un *undervolt*; se reinicia al apagar) |
| Windows | Grabación en segundo plano de Xbox Game Bar, limpieza de cachés de shaders |

Datos, respaldos y resultados: `%LOCALAPPDATA%\CS2-Optimizer\<cuenta>\`.

## Aviso

Proyecto independiente, sin relación con Valve. Úsalo bajo tu responsabilidad; todos los cambios son reversibles con **Restaurar todo**.

---

## 🇬🇧 English

**Optimize Counter-Strike 2 by measuring, not guessing.** CS2 Optimizer scans your PC (CPU, GPU, RAM channels, disk, laptop/desktop, monitor), recommends resolution / quality / FPS cap for your GPU tier, applies it with automatic backups, and compares real test runs using HWiNFO logs (FPS, 1% lows, CPU/GPU temps, thermal throttling), highlighting the best balance for *your* machine.

**VAC-safe by design:** only touches config files (`cs2_video.txt`, `autoexec.cfg`, launch options) and Windows settings (CPU power, NVIDIA clock limit, Game DVR). It never modifies game files or injects anything. Everything can be reverted with **Restore all**.

**Usage:** download ZIP → run `Iniciar.bat` (admin) → *Escaneo* (scan) → *Usar recomendación* → close CS2/Steam → *APLICAR* → log with HWiNFO while playing ~10 min → *Analizar CSV de HWiNFO*. The UI is currently in Spanish; English UI is on the roadmap. HWiNFO logs in English or Spanish are supported.

## Licencia / License

[MIT](LICENSE)
