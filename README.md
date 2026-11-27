# RemoteHub
1. Sube esta carpeta a un repo de GitHub.
2. Actions > Build IPA > Run workflow. Descarga el artefacto RemoteHub-ipa (RemoteHub.ipa).
3. Instálalo desde FlareStore / AltStore.
Sony: TV > Red doméstica > Control IP > Clave precompartida = 0000.
Samsung/LG: acepta el aviso en la TV la primera vez.

## Android TV / Google TV (incluye Philips modernos)
Pulsa "Emparejar con la TV", escribe el código de 6 caracteres que aparece en pantalla. Se hace una sola vez por TV.

## Descubrimiento
Bonjour + SSDP + escaneo de la subred. El multicast SSDP necesita el entitlement
`com.apple.developer.networking.multicast`; sin él iOS lo bloquea y el escaneo unicast lo reemplaza.
Si tu firmador lo soporta, agrega en project.yml bajo el target:
  entitlements: {path: RemoteHub.entitlements, properties: {com.apple.developer.networking.multicast: true}}

## Diagnóstico y log
Menú principal > "Diagnóstico y log": pruebas de red, de una TV y envío de tecla (Mute x2). El log se guarda en
el iPhone; usa "Compartir / guardar log" y adjúntalo. No incluye tokens, claves LG ni PSK de Sony (sí IPs y nombres de TV).

## IPA
El workflow genera un solo IPA: RemoteHub-multicast.ipa (lleva el entitlement de multicast embebido con ldid; si el firmador no lo respeta, el escaneo de subred lo reemplaza).

## Control: touchpad, teclado y atajos
- Touchpad: desliza = flechas (LG: cursor real), toca = OK.
- Teclado: botón "Teclado". Roku, LG, Samsung y Android TV/Philips (emparejado). Sony e IR no.
- Atajos: botón "Atajos". Lista las apps de la TV en Roku, LG, Samsung y Sony; en Android TV se usa paquete o enlace.
- "Conectado" aparece cuando la TV ya está vinculada. Al cancelar el emparejamiento se cierra el canal y se avisa a la TV.

## Icono
Sources/Assets.xcassets/AppIcon.appiconset/icon.png (1024x1024). Para cambiarlo, reemplaza ese archivo.

## Teclado (Android TV / Philips)
Usa el mismo canal de texto que la app oficial de Google (IME). Selecciona primero un campo de texto en la TV.
El log guarda solo la longitud del texto, no su contenido; aun así, no escribas contraseñas durante las pruebas.
