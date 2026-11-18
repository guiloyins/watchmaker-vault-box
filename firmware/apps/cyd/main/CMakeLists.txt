idf_component_register(SRCS app_main.cpp board_adapter.cpp network_adapter.cpp nvs_adapter.cpp
  INCLUDE_DIRS "." "${VAULT_BOARD_INCLUDE_DIR}"
  REQUIRES vault_device vault_display vault_transport esp_wifi esp_netif nvs_flash esp_timer
    esp_driver_uart esp_driver_gpio esp_driver_spi esp_lcd esp_hw_support mbedtls lvgl__lvgl
    atanisoft__esp_lcd_touch_xpt2046 espressif__esp_lcd_ili9341)
target_compile_features(${COMPONENT_LIB} PUBLIC cxx_std_17)
target_compile_options(${COMPONENT_LIB} PRIVATE -fno-exceptions -fno-rtti)
