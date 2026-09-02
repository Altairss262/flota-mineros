# Monitor de flota — Antminer S9

Sistema de monitorización y diagnóstico para una granja de 8 mineros Antminer S9 con Braiins OS+.
Lee las máquinas en la red local, publica un dashboard web y avisa por correo cuando algo falla.

**Dashboard en vivo →** https://altairss262.github.io/flota-mineros

---

## El problema

Siete S9 repartidos en una estantería, en un sitio con **cortes de luz de 5 a 7 horas diarias**
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

De todas las averías encontradas en la flota, **solo dos eran placas realmente muertas**.
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
| `VIGILAR.bat` / `VIGILAR.ps1` | Vigilancia en vivo en la terminal, se queda abierta |
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

## Dos formas de vigilar

Funcionan a la vez y no se estorban.

**En segundo plano.** `ENCENDER.bat` programa una tarea de Windows que cada 2
minutos lee la flota, publica el dashboard y avisa por correo. Se relanza sola
al encender el PC, así que sobrevive a los apagones. Para comprobar que sigue
viva: `.\programar-actualizacion.ps1 -Estado`.

**En vivo, delante de ti.** `VIGILAR.bat` abre una terminal que se queda
observando y redibuja el estado cada 20 segundos. No escribe nada, no manda
correos, no sube nada: solo mira. Lleva un registro de sucesos que anota
reinicios, placas perdidas o recuperadas, caídas de hashrate, apagones y
—lo más útil— **cuántas máquinas arrancaron cuando volvió la luz**.

Un uptime que baja significa que la máquina se reinició sola. Ese es el aviso
que delató el bucle de reinicios de Sara00.

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

## La causa de fondo: los conectores

Los ramales originales de las fuentes **se quemaron**. Se rehicieron con cable de
calibre 14 — más grueso que el 18 de fábrica, con margen de sobra para los ~25 A
que pide cada placa. Pero los **conectores PCIe** siguen siendo el eslabón débil:
se van achicharrando poco a poco, y cada conexión degradada calienta más y
acelera la siguiente.

Ese desgaste progresivo es lo que ha ido rompiendo la flota, no las placas.

**Pendiente principal: rehacer las conexiones con conectores PCIe nuevos** cuando lleguen.

Al montarlos conviene:
- Crimpados firmes — el cable 14 va apretado en un terminal pensado para el 18,
  y un crimpado flojo es una resistencia que se calienta
- Sujetar los cables cerca del conector con una brida, para que su peso no
  cuelgue de los pines
- Revisar los conectores viejos con linterna buscando plástico derretido o
  contactos ennegrecidos, y descartar los tocados

---

## Pendiente

- [ ] **Conectores PCIe nuevos** — en camino. Rehacer las conexiones de toda la flota.
- [x] **kiwi04** — desmantelada. Su placa buena pasó a Sara03, que vuelve a ir
      con las tres. La máquina sale de la flota: quedan 7.
- [ ] **Sara04** — verificar que el ventilador nuevo da las mismas vueltas que el otro
      (el viejo iba a 2.280 rpm contra 5.940 del compañero).
- [ ] **Sara00** — cadena 7 a 0 W y 0 chips con las otras dos a 375 W sobre la misma
      fuente: el fallo es del cable PCIe o del conector de ese slot, no de la fuente.
      Es el slot donde estaba la placa que hacía corto. La placa 6 arranca con 61
      chips de 63: conector desgastado, sigue pendiente de cambiar.
- [ ] Pasar el recolector a un dispositivo siempre encendido (un móvil con Termux
      o una Raspberry) para no depender del PC.

### Placas descartadas

| Placa | Estado |
|---|---|
| **Sara03, placa 6** | Muerta. Falla en el primer chip. Confirmada en dos slots con dos cables distintos. |
| **Sara00, placa 7** | Muerta. Hace corto y ahoga la fuente. No volver a montarla. |

Sirven como donantes de chips y de conectores.

---

## Hecho con

PowerShell 5.1 · HTML, CSS y JavaScript sin dependencias · SVG dibujado a mano ·
GitHub Pages · Web3Forms · API cgminer de Braiins OS+

Sin frameworks, sin servidor, sin coste.
