import type { State } from '../../types.js'
import express from 'express'
import { peerIdFromString } from '@libp2p/peer-id'
import { Multiaddr } from '@multiformats/multiaddr'
import { setupRestApi } from '../v2.js'
import { HoprDB, PublicKey } from '@hoprnet/hopr-utils'

export const ALICE_PEER_ID = peerIdFromString('16Uiu2HAmC9CRFeuF2cTf6955ECFmgDw6d27jLows7bftMqat5Woz')
export const ALICE_MULTI_ADDR = new Multiaddr(`/ip4/34.65.237.196/tcp/9091/p2p/${ALICE_PEER_ID.toString()}`)
export const ALICE_NATIVE_ADDR = PublicKey.fromPeerId(ALICE_PEER_ID).toAddress()
export const BOB_PEER_ID = peerIdFromString('16Uiu2HAm29vyHEGNm6ebghEs1tm92UxfaNtj8Rc1Y4qV4TAN5xyQ')
export const BOB_MULTI_ADDR = new Multiaddr(`/ip4/34.65.237.197/tcp/9091/p2p/${BOB_PEER_ID.toString()}`)
export const CHARLIE_PEER_ID = peerIdFromString('16Uiu2HAmUsJwbECMroQUC29LQZZWsYpYZx1oaM1H9DBoZHLkYn12')
export const INVALID_PEER_ID = 'definetly not a valid peerId'

export const TICKET_MOCK = {
  counterparty: { toHex: () => '', toBN: () => '' },
  challenge: { toHex: () => '', toBN: () => '' },
  epoch: { toHex: () => '', toBN: () => '' },
  index: { toHex: () => '', toBN: () => '' },
  amount: { toHex: () => '', toBN: () => '' },
  winProb: { toHex: () => '', toBN: () => '' },
  channelEpoch: { toHex: () => '', toBN: () => '' },
  signature: { toHex: () => '', toBN: () => '' }
}

/**
 * Creates express app and initializes all routes for testing
 * @returns apiInstance for openAPI validation and express instance for supertest requests
 */
export const createTestApiInstance = async (node: any) => {
  const service = express()
  return {
    api: await setupRestApi(service, '/api/v2', node, createTestMocks(), {
      disableApiAuthentication: true
    }),
    service
  }
}

/**
 * Creates express app and initializes all routes for testing
 * @returns apiInstance for openAPI validation and express instance for supertest requests with superuser authentication token set to superuser
 */
export const createAuthenticatedTestApiInstance = async (node: any) => {
  const service = express()
  return {
    api: await setupRestApi(service, '/api/v2', node, createTestMocks(), {
      apiToken: 'superuser'
    }),
    service
  }
}

/**
 * Used in tests to create state mocking.
 * @returns testing mocks
 */
export const createTestMocks = () => {
  let state: State = {
    aliases: new Map(),
    settings: { includeRecipient: false, strategy: 'passive', maxAutoChannels: undefined, autoRedeemTickets: false }
  }

  return {
    setState(s: State) {
      state = s
    },
    getState() {
      return state
    }
  }
}

/**
 * Used in tests to create a db mock for generic object storage
 * @returns testing mocked db
 */
export const createMockDb = () => {
  const store = {}
  const key = (ns: string, id: string) => `${ns}:${id}`
  const db = {
    putSerializedObject: async (ns: string, id: string, object: Uint8Array): Promise<void> => {
      store[key(ns, id)] = object
      return
    },
    getSerializedObject: async (ns: string, id: string): Promise<Uint8Array | undefined> => {
      return store[key(ns, id)]
    },
    deleteObject: async (ns: string, id: string): Promise<void> => {
      delete store[key(ns, id)]
      return
    }
  }
  return db as any as HoprDB
}
