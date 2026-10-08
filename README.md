# PharmaTrace: demo EVM de trazabilidad de medicamentos (Fase 1)

Demo educativa. NO es un sistema oficial ni afirma cumplimiento regulatorio de ningun pais.
Todo corre en Anvil local: costo $0, sin dinero real, sin claves reales.

## Que modela
```
Regulador --licencia--> ActorRegistry (laboratorio / drogueria / farmacia, con vigencia)
Laboratorio --registerBatch--> MedicineRegistry (hashes + raiz Merkle de series)
Laboratorio -> Drogueria -> Farmacia   (transferCustody, validado contra licencias)
Farmacia --dispense(serie + proof)--> la serie queda marcada: no se puede dispensar dos veces
Cualquiera --verifyUnit--> Valid | AlreadyDispensed | Recalled | Expired | InvalidProof | UnknownBatch
```

## Que va on-chain y que no
- On-chain: address del actor + tipo + vigencia; hash de GTIN, hash de lote, raiz Merkle de series, custodio, estados, eventos.
- Off-chain: razon social, datos de pacientes, recetas, documentos, temperaturas, todo dato privado u operativo.
- on-chain != verdad: se prueba que un dato no cambio desde que se anclo, no que fuera cierto.

## Reglas de hash (reproducibles)
- productHash = keccak256(bytes(GTIN))   (UTF-8)
- lotHash     = keccak256(bytes(lote))
- serial      = keccak256(bytes(numeroDeSerie))
- hoja Merkle = keccak256(abi.encodePacked(serial)); nodos con par ordenado (OZ MerkleProof)
- batchId     = keccak256(abi.encode(manufacturer, productHash, lotHash))
- Ojo: este formato de hoja NO coincide con @openzeppelin/merkle-tree (usa doble hash); en la fase viem usaremos esta misma regla.

## Setup (una vez)
```bash
curl -L https://foundry.paradigm.xyz | bash && foundryup
forge init pharmatrace
cd pharmatrace && rm -f src/Counter.sol test/Counter.t.sol script/Counter.s.sol
forge install OpenZeppelin/openzeppelin-contracts
```
Copia encima: src/ (incluye interfaces/), test/, script/, foundry.toml, .gitignore.

## Uso
```bash
forge fmt && forge build
forge test -vv
forge test --gas-report
```

## Demo local con Anvil (sin claves en archivos)
Las cuentas de Anvil vienen desbloqueadas: se firman con `--unlocked --from`.
```bash
anvil    # terminal 1

# terminal 2
export RPC=http://127.0.0.1:8545
export REG_ADMIN=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266   # cuenta #0 = regulador
export MFR=0x70997970C51812dc3A010C7d01b50e0d17dc79C8          # #1 laboratorio
export DIST=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC         # #2 drogueria
export PHARM=0x90F79bf6EB2c4f870365E785982E1f101E93b906        # #3 farmacia
export EXP=$(( $(date +%s) + 31536000 ))

forge script script/Deploy.s.sol --rpc-url $RPC --broadcast --unlocked --sender $REG_ADMIN
export ACT=<ActorRegistry>   REG=<MedicineRegistry>

# habilitar actores (1=Manufacturer 2=Distributor 3=Pharmacy)
cast send $ACT "licenseActor(address,uint8,uint64)" $MFR  1 $EXP --rpc-url $RPC --unlocked --from $REG_ADMIN
cast send $ACT "licenseActor(address,uint8,uint64)" $DIST 2 $EXP --rpc-url $RPC --unlocked --from $REG_ADMIN
cast send $ACT "licenseActor(address,uint8,uint64)" $PHARM 3 $EXP --rpc-url $RPC --unlocked --from $REG_ADMIN

# raiz Merkle y pruebas de ejemplo
forge script script/MerkleDemo.s.sol
export ROOT=<ROOT>   SERIAL=<serial SN-0001>   P0=<proof[0]>   P1=<proof[1]>

export PRODUCT=$(cast keccak "07791234567890")  LOT=$(cast keccak "LOTE-A001")
cast send $REG "registerBatch(bytes32,bytes32,bytes32,uint64)" $PRODUCT $LOT $ROOT $EXP --rpc-url $RPC --unlocked --from $MFR
export BATCH=$(cast call $REG "computeBatchId(address,bytes32,bytes32)(bytes32)" $MFR $PRODUCT $LOT --rpc-url $RPC)

cast send $REG "transferCustody(bytes32,address)" $BATCH $DIST  --rpc-url $RPC --unlocked --from $MFR
cast send $REG "transferCustody(bytes32,address)" $BATCH $PHARM --rpc-url $RPC --unlocked --from $DIST

cast call $REG "verifyUnit(bytes32,bytes32,bytes32[])(uint8)" $BATCH $SERIAL "[$P0,$P1]" --rpc-url $RPC   # 5 = Valid
cast send $REG "dispense(bytes32,bytes32,bytes32[])" $BATCH $SERIAL "[$P0,$P1]" --rpc-url $RPC --unlocked --from $PHARM
cast call $REG "verifyUnit(bytes32,bytes32,bytes32[])(uint8)" $BATCH $SERIAL "[$P0,$P1]" --rpc-url $RPC   # 4 = AlreadyDispensed
cast logs --address $REG --rpc-url $RPC
```
Si tu version de forge no acepta `--unlocked --sender`, usa `forge create` o un keystore con `--account`.

## Decisiones de diseno
- Batch-level + Merkle: guardar cada serie on-chain seria carisimo; la raiz permite verificar cualquier unidad.
- Custodia validada contra licencias vigentes: vencida o suspendida => no puede despachar ni dispensar.
- Recall siempre disponible para el fabricante y el regulador, incluso con licencia vencida. Irreversible en v1.
- Sin upgradeability ni ETH en contratos.
- Limitaciones: custodia por lote completo (sin fraccionar); un regulador comprometido compromete el padron (en produccion: multisig/gobernanza).

## Roadmap
1. (esta fase) Identidad institucional + lotes + custodia + dispensa + recall
2. Invariants (una serie nunca se dispensa dos veces; un lote retirado no se mueve)
3. Cadena de frio: anclaje de hashes de lecturas de temperatura
4. Regulador como multisig/Governor (DAO real: el consejo habilita actores por votacion)
5. viem + frontend de verificacion (QR -> verifyUnit) con MetaMask
6. Sepolia / Polygon Amoy
7. Opcional (RWA/DeFi): financiamiento de facturas de drogueria con un token de credito
