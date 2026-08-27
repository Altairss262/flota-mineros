# Monitor de flota — Antminer S9

Sistema de monitorización y diagnóstico para una granja de 8 mineros Antminer S9 con Braiins OS+.
Lee las máquinas en la red local, publica un dashboard web y avisa por correo cuando algo falla.

**Dashboard en vivo →** https://altairss262.github.io/flota-mineros

---

## El problema

Ocho S9 repartidos en una estantería, en un sitio con **cortes de luz de 5 a 7 horas diarias**
y sin aire acondicionado. Cada corte y cada arranque castiga fuentes y conectores.
La flota pasó de 12 máquinas a 8 por desgaste.

Sin monitorización, enterarse de que una placa dejó de minar podía llevar días.

---

## Cómo funciona

```
   MINEROS (red local 192.168.0.x)
   API cgminer en el puerto 4028
                │
                ▼
   ┌────────────────────────────────────┐
   │  recolector.ps1   cada 2 minutos   │
   │                                    │
   │  1. lee los 8 mineros              │
   │  2. genera datos.json              │
   │  3. compara con la lectura previa  │
   │  4. si algo empeoró → correo       │
   │  5. sube los datos a GitHub        │
   └───────────────┬────────────────────┘
                   │
        ┌──────────┴──────────┐
        ▼                     ▼
   GitHub Pages           Correo
   (el dashboard)         (los avisos)
```

Los mineros están en una red privada: nada de internet puede alcanzarlos.
Por eso un equipo dentro de la red hace de recolector y publica los datos fuera.

**Durante los apagones el recolector se calla solo**: detecta que toda la flota sigue
caída y deja de subir datos hasta que vuelve la corriente.

---

## El dashboard

- Hashrate total, consumo, mineros en pie y placas minando
- Indicador de frescura que avisa si los datos están viejos
- Gráfica de hashrate de las últimas 24 horas, con detalle al pasar el dedo
- Una tarjeta por minero: barra de hashrate, temperatura en color, ventiladores
- Detalle de las 24 placas: chips detectados, vatios y grados
- Panel de avisos con interruptores (vista previa; se aplican editando la configuración)
- Modo claro y oscuro, pensado para el móvil

---

## Método de diagnóstico

La parte más útil del proyecto no es el código: es haber aprendido a **leer los logs**
de Braiins OS para saber qué falla sin desmontar nada.

De todas las averías encontradas en la flota, **solo una era una placa realmente muerta**.
El resto eran cables, conectores y fuentes.

### Tabla de síntomas

| Lo que dice el log | Chips | Qué es | Mirar primero |
|---|---|---|---|
| `Discovered 63 chips` + `Stable` | 63 | Placa sana | Nada |
| El minero **no nombra** la placa | — | Sin conexión de datos | Cable plano suelto o roto |
| `no chips detected`, **siempre igual**, falla en <0,2 s | 0 | La cadena no tiene alimentación | Cable PCIe de 12 V, o la fuente |
| `not enough chips on chain`, número que **varía** | varía | Falso contacto | Pines del conector, limpieza |
| `unexpected revision of chip N` | — | Respuesta corrupta, señal sucia | Soldaduras, cable de datos |
| `I/O error (os error 5)` + fallos de I2C | — | Enlace de datos inestable | Cable plano |
| Contador `J6/J7/J8` alto en una sola | — | Interferencias en ese conector | Pines desgastados |

### Las tres reglas que más tiempo ahorran

**1. Compara los reintentos entre sí.** El minero reintenta cada 17 segundos.
Errores que **varían** = fallo intermitente = contacto o soldadura.
Errores **idénticos** cincuenta veces = fallo duro = alimentación.

**2. Si fallan las tres placas a la vez, es la fuente.** Tres placas no se mueren juntas.

**3. Una placa en corto ahoga la fuente entera** y hace parecer que las demás están rotas.
Desconectarla puede resucitar el resto de la máquina.

### Arquitectura de una placa S9

63 chips BM1387 en **21 dominios de 3 chips**. Los 3 de cada dominio van en paralelo;
los 21 dominios van **en serie** sobre el raíl (~8,5 V), cayendo ~0,4 V cada uno.

Medida con multímetro, dominio a dominio:

| Lectura | Significa |
|---|---|
| ≈ 0,40 V | Dominio sano |
| 0,00 V | Chip en corto |
| ≈ 8,5 V | Chip abierto — el culpable |

El diseño en serie es lo que hace eficiente a la máquina: en paralelo harían falta
750 amperios; en serie bastan 35. El precio es que **un chip malo tumba la placa entera**.

---

## Archivos

| Archivo | Para qué |
|---|---|
| `index.html` | El dashboard |
| `recolector.ps1` | Lee los mineros, genera los datos, avisa y sube |
| `alertas.config.json` | Selector de avisos — editable desde GitHub |
| `programar-actualizacion.ps1` | Instala la tarea programada |
| `ENCENDER.bat` / `APAGAR.bat` | Encender y apagar el monitor, sin consola |
| `datos.json` | Estado actual (lo genera el recolector) |
| `historial.json` | 24 horas de hashrate para la gráfica |
| `test-placas.ps1` | Diagnóstico rápido de un minero concreto |

`correo.local.json` guarda las credenciales del correo y **nunca se sube**: está en `.gitignore`.

---

## Puesta en marcha

```powershell
# 1. Editar la lista de mineros en recolector.ps1

# 2. Probar
.\recolector.ps1 -SinSubir -Ver

# 3. Conectar con un repositorio propio
.\configurar-github.ps1 -Usuario TU_USUARIO -Repo flota-mineros
git push -u origin main

# 4. Activar GitHub Pages en Settings -> Pages -> main / (root)

# 5. Dejarlo funcionando solo
.\ENCENDER.bat
```

Para los avisos por correo: copiar la plantilla de `correo.local.json`, poner una
cuenta de Gmail con clave de aplicación, y cambiar `activado` a `true`.

---

## Selector de avisos

`alertas.config.json` decide qué merece un correo. Se puede editar desde GitHub,
también desde el móvil, y el recolector lo recoge en el siguiente ciclo.

| Aviso | Por defecto |
|---|---|
| Minero deja de responder | ❌ desactivado — los cortes de luz no son noticia |
| Una placa deja de minar | ✅ |
| Temperatura sobre 95° | ✅ |
| Ventilador parado o flojo | ✅ |
| Caída de hashrate del 25% | ✅ |
| Placa con menos de 63 chips | ❌ |
| Avisar de recuperaciones | ✅ |

Máximo un correo cada 15 minutos, y solo cuando el estado **cambia**.

---

## Pendiente

- [ ] **kiwi04** — placas 7 y 8 sin corriente con los cables puestos. Probable fuente.
      Prueba: pasarle a la placa 7 el cable de la placa 6, que sí funciona.
- [ ] **Sara04** — verificar que el ventilador nuevo da las mismas vueltas que el otro
      (el viejo iba a 2.280 rpm contra 5.940 del compañero).
- [ ] **Sara00** — placa 6 con ~32.000 interferencias: conector de la placa desgastado.
      Es la única que justificaría desmontar para cambiar el conector.
- [ ] **Sara03** — placa 6 sin probar. Le faltan cable de datos y de corriente a la vez.
- [ ] Pasar el recolector a un dispositivo que esté siempre encendido (un móvil
      con Termux o una Raspberry) para no depender del PC.

---

## Hecho con

PowerShell 5.1 · HTML, CSS y JavaScript sin dependencias · SVG dibujado a mano ·
GitHub Pages · Web3Forms · API cgminer de Braiins OS+

Sin frameworks, sin servidor, sin coste.
