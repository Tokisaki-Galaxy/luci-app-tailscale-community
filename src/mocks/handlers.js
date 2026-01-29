import { http, HttpResponse } from 'msw'

export const handlers = [
  // 示例：拦截获取用户信息的请求
  http.get('/api/user', () => {
    return HttpResponse.json({
      id: 'c7b3d8e0-5e0b-4b0f-8b0a-6b0a6b0a6b0a',
      firstName: 'John',
      lastName: 'Maverick',
    })
  }),
]
