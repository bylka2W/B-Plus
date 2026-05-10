# B+ v1.0 — Язык программирования для GPU/TSS

B+ — язык для высокопроизводительных вычислений с безопасной типизацией, векторными ядрами и асинхронным IO.

## Структура проекта

```
B+ v1.0/
├── src/           — Исходный код компилятора/рантайма
├── examples/      — Примеры на B+
├── docs/          — Документация и спецификация
└── README.md      — Этот файл
```

## Пример

```bplus
-- Ядро генерации шума с запеченным апскейлом
@export("Gen_TSS_Noise")
@vectorized(width: 512, fma: true)
@fuse(spatial)
fn generate_noise[H: Dim, W: Dim](
    output: NoiseBuffer[H, W],
    seed: f32,
    scale: f32
) {
    body:
        let x_coord = @index_x * scale + seed
        let y_coord = @index_y * scale + seed
        let val = sin(x_coord) * cos(y_coord) * seed
        @activation(relu) {
            val >> output[@index_x, @index_y]
        }
}
```

## Лицензия

MIT
