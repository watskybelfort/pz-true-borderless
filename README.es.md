# True Borderless — para Project Zomboid Build 42

[English](README.md) · **Español**

Pantalla completa sin bordes que de verdad cubre el monitor, y un **alt-tab que nunca
se pone en negro**.

Ya sabes de qué parpadeo hablo. Te sales a Discord, la pantalla se queda negra medio
segundo, vuelves, y se pone negra otra vez. Eso es lo que esto quita.

Son dos piezas:

| | Solo el mod de la Workshop | Mod **+** este ayudante |
|---|:---:|:---:|
| El borderless cubre la pantalla de verdad, barra de tareas incluida | ✅ | ✅ |
| Al desactivarlo recuperas tu configuración de antes | ✅ | ✅ |
| Funciona en un **segundo** monitor | ❌ | ✅ |
| **Alt-tab sin parpadeo negro** | ❌ | ✅ |

El mod arregla el borderless. El ayudante es lo que hace el alt-tab seamless, y tiene
que vivir fuera del juego porque Lua no puede llamar a la API de Windows.
[Por qué, en detalle](#por-qué-hace-falta-un-archivo-fuera-del-juego).

---

## Instalación — tres pasos, unos dos minutos

### 1. Suscríbete al mod

Steam Workshop → **True Borderless** → Suscribirse, y actívalo en la pantalla de
**Mods** del juego como cualquier otro.

> Puedes quedarte aquí. Tendrás borderless funcionando; lo que no tendrás es el
> alt-tab seamless.

### 2. Descarga este ayudante

Botón verde **Code** arriba en esta página → **Download ZIP**.

Descomprímelo **donde quieras** y déjalo ahí — en Documentos, en la carpeta del juego,
en una carpeta del escritorio. Da igual, mientras no lo muevas después.

No hay que instalar nada. Son dos archivos:

```
TrueBorderless.ps1        el ayudante
TrueBorderless-Steam.bat  el archivito al que llama Steam
```

### 3. Dile a Steam que lo use

1. Clic derecho en **Project Zomboid** en tu biblioteca → **Propiedades**
2. En **General**, busca abajo la caja **Opciones de lanzamiento**
3. Pega esto, **cambiando la ruta por la tuya**:

```
"C:\Ruta\A\pz-true-borderless\TrueBorderless-Steam.bat" %command%
```

**Deja las comillas, y deja ` %command%` al final.** Esas dos cosas son las que hacen
que funcione.

<details>
<summary><b>¿Cómo saco mi ruta?</b> (clic)</summary>

Abre la carpeta donde lo descomprimiste, mantén **Mayús**, clic derecho en
`TrueBorderless-Steam.bat`, y elige **Copiar como ruta de acceso**. Windows te la
copia *ya con las comillas puestas*. Pégala en la caja, pulsa espacio y escribe
`%command%` detrás.

Queda así:

```
"C:\Users\Tu\Documents\pz-true-borderless\TrueBorderless-Steam.bat" %command%
```
</details>

### Ya está

Dale a **Jugar**. Verás pasar una ventanita mientras prepara las cosas, y arranca el
juego. Haz alt-tab y vuelve: sin negros.

A partir de ahí da igual *cómo* arranques el juego: el botón Jugar, un acceso directo
del escritorio, Big Picture, un enlace `steam://`. Steam siempre pasa primero por las
opciones de lanzamiento, así que siempre funciona. Y con el juego cerrado no queda
nada corriendo.

---

## Comprobar que funcionó

Haz alt-tab y vuelve. Si la pantalla no se apaga en ningún momento, listo.

¿Quieres los detalles? Abre la carpeta, escribe `powershell` en la barra de
direcciones, pulsa Enter, y ejecuta:

```powershell
.\TrueBorderless.ps1 -Mode Status
```

Te imprime tus monitores, qué está haciendo la ventana del juego ahora mismo, y una
lista de todo lo que todavía podría provocar un parpadeo. Todas las líneas deberían
decir `ok`.

---

## Desinstalar

1. Vacía la caja de **Opciones de lanzamiento** en Steam.
2. Devuelve a Windows lo suyo:

   ```powershell
   .\TrueBorderless.ps1 -Mode SeamlessUndo
   .\TrueBorderless.ps1 -Mode Revert
   ```

3. Borra la carpeta. Y desuscríbete del mod si quieres.

`-Mode Revert` te devuelve la resolución y el modo de pantalla que tenías **antes de
ejecutar esto por primera vez**, no lo que el programa hubiera dejado puesto. Los
guardó en el primer arranque justo para esto.

---

## ¿Por qué hace falta un archivo fuera del juego?

Resumen: el último parpadeo negro lo causa Windows, no Project Zomboid, y un mod no
tiene forma de hablar con Windows.

La versión larga, porque conviene saber qué estás ejecutando:

Una ventana sin bordes cuyo rectángulo coincide **exactamente** con un monitor es
ascendida por Windows a la ruta de presentación de pantalla completa. Normalmente eso
es *bueno*: es como los juegos en borderless consiguen el rendimiento de fullscreen. El
precio es que también heredas las transiciones del fullscreen, así que el alt-tab apaga
el panel mientras mueve la ventana dentro y fuera de esa ruta.

El arreglo es casi tonto: hacer la ventana **un píxel más grande que el monitor**, de
forma que sobresalga un píxel por cada lado. Ya no coincide exactamente, Windows la
deja compuesta como una ventana normal, y el alt-tab es instantáneo. El píxel que falta
no lo ves nunca — está fuera de pantalla.

Colocar una ventana en `-1, -1` y darle un tamaño que pase del borde significa llamar a
`SetWindowLongPtr` y a `SetWindowPos`. El sandbox de Lua de Project Zomboid no tiene
acceso a ninguna de las dos, y ningún mod puede añadírselo. Así que ese trabajo — y
solo ese — vive en un script fuera del juego.

El desarrollo técnico completo, incluidos los cuatro fallos distintos del borderless de
vanilla y cómo se encontraron, está en [docs/how-it-works.md](docs/how-it-works.md).

---

## ¿Es seguro ejecutar esto?

Pregunta justa: hay que desconfiar de los `.bat` que uno se baja de internet.

- **Está todo aquí, en texto plano.** `TrueBorderless.ps1` es un solo archivo que
  puedes leer de arriba abajo, y está comentado para personas, no para compiladores.
- **No pide permisos de administrador.** Nada de lo que toca lo necesita.
- **No usa la red.** No se conecta a nada. No hay a dónde llamar.
- **No deja nada corriendo.** El ayudante se cierra solo cuando cierras el juego. No
  se añade al inicio de Windows ni instala ningún servicio.

Todo lo que escribe, sin más:

| Qué | Dónde | Cómo se deshace |
|---|---|---|
| Sus propios ajustes | `Documentos\Zomboid\Lua\TrueBorderless*.ini` | bórralos |
| Resolución y modo de pantalla | `Documentos\Zomboid\options.ini` (deja una copia de seguridad al lado en el primer arranque) | `-Mode Revert` |
| "Deshabilitar optimizaciones de pantalla completa" | `HKCU\...\AppCompatFlags\Layers` — el mismo valor del registro que escribe esa casilla en las Propiedades de un programa | `-Mode SeamlessUndo` |

Lo último merece una nota: es por usuario, es exactamente lo mismo que harías a mano en
`ProjectZomboid64.exe` → Propiedades → Compatibilidad, y el script *edita* el valor en
vez de reemplazarlo, así que las opciones de compatibilidad de otras herramientas
sobreviven.

---

## Si algo va mal

Casi siempre es una de cuatro cosas — la lista completa está en
[docs/troubleshooting.md](docs/troubleshooting.md).

**El juego abre como una ventana normal, con barra de título.**
No se está usando la opción de lanzamiento. Comprueba que está en la caja de
**Opciones de lanzamiento** (no en los ajustes del propio juego), que la ruta es
correcta, y que ` %command%` está al final.

**Steam dice que llevo 0 horas / no funciona el overlay.**
Falta el ` %command%` del final.

**"No se puede cargar el archivo... la ejecución de scripts está deshabilitada".**
No tienes que arreglar nada: el `.bat` ya lanza PowerShell con
`-ExecutionPolicy Bypass`. Si estás ejecutando el `.ps1` a mano, usa
`powershell -ExecutionPolicy Bypass -File .\TrueBorderless.ps1`.

**Funciona, pero la ventana sale en el monitor equivocado.**
Abre `Documentos\Zomboid\Lua\TrueBorderless.ini` y pon en `monitor=` el número que
quieras. Con `-Mode Status` ves cómo están numerados.

---

## Ajustes

Todo está en un archivo, `Documentos\Zomboid\Lua\TrueBorderless.ini`, y va escrito con
comentarios que se explican solos. Lo leen tanto el mod como el ayudante, así que solo
hay un sitio donde cambiar nada. El panel del juego en **Opciones → Opciones de mods →
True Borderless** escribe en ese mismo archivo.

| Ajuste | Por defecto | Qué hace |
|---|---|---|
| `mode` | `true` | `true` = el ayudante controla la ventana (alt-tab seamless, funciona en cualquier monitor). `native` = solo el borderless del motor, sin ayudante. `off` = no tocar la pantalla. |
| `overscan` | `1` | Píxeles que la ventana sobresale por cada lado. Este es el truco entero. `0` lo desactiva. |
| `monitor` | `auto` | `auto`, `primary`, o el número de un monitor. |
| `topmost` | `false` | Mantener la ventana por encima de todo. |

**F10** lo activa y lo desactiva dentro del juego. Se puede reasignar en
**Opciones → Controles**.

---

## Requisitos

- **Windows.** El ayudante usa la API Win32. El mod por su cuenta es Lua puro y
  funciona en todas partes, pero solo te dará el modo `native`.
- **Project Zomboid Build 42.** Sin probar en B41.
- PowerShell 5.1, que viene con Windows. No hay que instalar nada.

## Licencia

MIT — ver [LICENSE](LICENSE). Haz lo que quieras con esto.
